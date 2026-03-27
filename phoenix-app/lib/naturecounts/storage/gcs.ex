defmodule Naturecounts.Storage.GCS do
  @moduledoc """
  Google Cloud Storage client with per-bucket credentials.
  Each bucket config carries its own service account JSON,
  enabling multi-tenant GCS access without global config.

  Generates self-signed JWTs for auth — no Goth dependency.
  """

  require Logger

  @base_url "https://storage.googleapis.com"
  @video_extensions ~w(.mp4 .avi .mkv .mov .ts)
  @token_ttl 3600

  @doc """
  List objects in a GCS bucket under the given prefix.
  `bucket_config` must have "bucket" and "credentials" keys.
  """
  def list_objects(bucket_config, prefix \\ "") do
    bucket = bucket_config["bucket"]
    prefix = if prefix != "" and not String.ends_with?(prefix, "/"), do: prefix <> "/", else: prefix

    case api_get(bucket_config, "/storage/v1/b/#{bucket}/o", %{
           prefix: prefix,
           delimiter: "/",
           maxResults: 1000,
           fields: "items(name,size,updated,contentType),prefixes,nextPageToken"
         }) do
      {:ok, %{status: 200, body: body}} ->
        dirs =
          (body["prefixes"] || [])
          |> Enum.map(fn p ->
            name = p |> String.trim_trailing("/") |> Path.basename()
            %{type: :dir, name: name, path: p, size_mb: 0}
          end)

        files =
          (body["items"] || [])
          |> Enum.filter(fn item ->
            ext = item["name"] |> Path.extname() |> String.downcase()
            ext in @video_extensions and item["name"] != prefix
          end)
          |> Enum.map(fn item ->
            size_bytes = String.to_integer(item["size"] || "0")

            %{
              type: :file,
              name: Path.basename(item["name"]),
              path: item["name"],
              size_mb: Float.round(size_bytes / 1_048_576, 1),
              processed: nil,
              metrics: nil
            }
          end)

        {:ok, dirs ++ files}

      {:ok, %{status: status, body: body}} ->
        {:error, "GCS API error #{status}: #{inspect(body["error"]["message"])}"}

      {:error, reason} ->
        {:error, "GCS request failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Generate a V4 signed URL for direct browser access to a GCS object.
  Supports Range requests for video seeking.
  """
  def signed_url(bucket_config, object_path, ttl_seconds \\ 3600) do
    bucket = bucket_config["bucket"]
    credentials = bucket_config["credentials"]

    if credentials == nil do
      {:error, "No credentials configured for this bucket"}
    else
      now = DateTime.utc_now()
      credential_datetime = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
      date_stamp = Calendar.strftime(now, "%Y%m%d")

      client_email = credentials["client_email"]
      private_key_pem = credentials["private_key"]

      credential_scope = "#{date_stamp}/auto/storage/goog4_request"
      credential = "#{client_email}/#{credential_scope}"

      encoded_object = object_path |> String.split("/") |> Enum.map(&URI.encode/1) |> Enum.join("/")
      host = "storage.googleapis.com"
      resource = "/#{bucket}/#{encoded_object}"

      query_params = [
        {"X-Goog-Algorithm", "GOOG4-RSA-SHA256"},
        {"X-Goog-Credential", credential},
        {"X-Goog-Date", credential_datetime},
        {"X-Goog-Expires", to_string(ttl_seconds)},
        {"X-Goog-SignedHeaders", "host"}
      ]

      canonical_query = query_params |> Enum.sort() |> URI.encode_query()

      canonical_request =
        Enum.join(
          [
            "GET",
            resource,
            canonical_query,
            "host:#{host}\n",
            "host",
            "UNSIGNED-PAYLOAD"
          ],
          "\n"
        )

      string_to_sign =
        Enum.join(
          [
            "GOOG4-RSA-SHA256",
            credential_datetime,
            credential_scope,
            :crypto.hash(:sha256, canonical_request) |> Base.encode16(case: :lower)
          ],
          "\n"
        )

      signature = rsa_sign(string_to_sign, private_key_pem)
      signed_url = "#{@base_url}#{resource}?#{canonical_query}&X-Goog-Signature=#{signature}"

      {:ok, signed_url}
    end
  end

  @doc """
  Download a GCS object to a local file path. Streams the response body.
  """
  def download(bucket_config, object_path, dest_path) do
    bucket = bucket_config["bucket"]
    File.mkdir_p!(Path.dirname(dest_path))
    encoded = URI.encode(object_path, &URI.char_unreserved?/1)

    case get_token(bucket_config) do
      {:ok, token} ->
        url = "#{@base_url}/storage/v1/b/#{bucket}/o/#{encoded}?alt=media"

        case Req.get(url,
               headers: [{"authorization", "Bearer #{token}"}],
               into: File.stream!(dest_path),
               receive_timeout: 600_000
             ) do
          {:ok, %{status: 200}} ->
            {:ok, dest_path}

          {:ok, %{status: status}} ->
            File.rm(dest_path)
            {:error, "GCS download failed with status #{status}"}

          {:error, reason} ->
            File.rm(dest_path)
            {:error, "GCS download error: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Test connectivity to a bucket using the provided credentials.
  Returns :ok or {:error, reason}.
  """
  def test_connection(bucket_config) do
    bucket = bucket_config["bucket"]

    case api_get(bucket_config, "/storage/v1/b/#{bucket}", %{fields: "name"}) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 403}} -> {:error, "Access denied — check service account permissions"}
      {:ok, %{status: 404}} -> {:error, "Bucket '#{bucket}' not found"}
      {:ok, %{status: status, body: body}} -> {:error, "HTTP #{status}: #{inspect(body["error"]["message"])}"}
      {:error, reason} -> {:error, "Connection failed: #{inspect(reason)}"}
    end
  end

  # --- Private ---

  defp api_get(bucket_config, path, params) do
    case get_token(bucket_config) do
      {:ok, token} ->
        Req.get("#{@base_url}#{path}",
          params: Map.to_list(params),
          headers: [{"authorization", "Bearer #{token}"}],
          receive_timeout: 30_000
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Generate a self-signed JWT for GCS API access from service account credentials.
  # Google Cloud Storage accepts these directly as Bearer tokens.
  defp get_token(bucket_config) do
    credentials = bucket_config["credentials"]

    cond do
      credentials == nil ->
        {:error, "No credentials configured for this bucket"}

      credentials["client_email"] == nil or credentials["private_key"] == nil ->
        {:error, "Invalid credentials: missing client_email or private_key"}

      true ->
        now = System.system_time(:second)

        header = %{"alg" => "RS256", "typ" => "JWT"}
        claims = %{
          "iss" => credentials["client_email"],
          "sub" => credentials["client_email"],
          "aud" => "https://storage.googleapis.com/",
          "iat" => now,
          "exp" => now + @token_ttl
        }

        header_b64 = Base.url_encode64(Jason.encode!(header), padding: false)
        claims_b64 = Base.url_encode64(Jason.encode!(claims), padding: false)
        unsigned = "#{header_b64}.#{claims_b64}"

        [entry] = :public_key.pem_decode(credentials["private_key"])
        key = :public_key.pem_entry_decode(entry)
        signature = :public_key.sign(unsigned, :sha256, key) |> Base.url_encode64(padding: false)

        {:ok, "#{unsigned}.#{signature}"}
    end
  rescue
    e -> {:error, "Token generation failed: #{Exception.message(e)}"}
  end

  defp rsa_sign(data, pem) do
    [entry] = :public_key.pem_decode(pem)
    key = :public_key.pem_entry_decode(entry)
    :public_key.sign(data, :sha256, key) |> Base.encode16(case: :lower)
  end
end

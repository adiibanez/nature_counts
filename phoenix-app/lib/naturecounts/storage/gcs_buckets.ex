defmodule Naturecounts.Storage.GCSBuckets do
  @moduledoc """
  Persists user-configured GCS bucket entries to a JSON file.
  Each bucket has a name (display label), bucket ID, optional prefix,
  and its own service account credentials for multi-tenant access.
  """

  @path Application.compile_env(:naturecounts, :gcs_buckets_path, "/data/gcs_buckets.json")

  def list do
    read()
  end

  @doc "Returns full bucket config including credentials."
  def get(id) do
    Enum.find(list(), fn b -> b["id"] == id end)
  end

  @doc "Returns bucket config with credentials redacted (for UI display)."
  def get_safe(id) do
    case get(id) do
      nil -> nil
      b -> redact(b)
    end
  end

  @doc "List buckets with credentials redacted (for UI)."
  def list_safe do
    Enum.map(list(), &redact/1)
  end

  def add(name, bucket, prefix, credentials_json \\ nil) do
    id = slugify(name)
    credentials = parse_credentials(credentials_json)

    entry = %{
      "id" => id,
      "name" => name,
      "bucket" => bucket,
      "prefix" => prefix,
      "credentials" => credentials
    }

    buckets = list()

    case Enum.find_index(buckets, fn b -> b["id"] == id end) do
      nil -> write(buckets ++ [entry])
      idx -> write(List.replace_at(buckets, idx, entry))
    end

    id
  end

  def update(id, attrs) do
    buckets = list()

    case Enum.find_index(buckets, fn b -> b["id"] == id end) do
      nil ->
        {:error, :not_found}

      idx ->
        existing = Enum.at(buckets, idx)

        updated =
          existing
          |> maybe_put("name", attrs["name"])
          |> maybe_put("bucket", attrs["bucket"])
          |> maybe_put("prefix", attrs["prefix"])

        # Only update credentials if new ones are provided (non-empty)
        updated =
          case attrs["credentials_json"] do
            json when is_binary(json) and json != "" ->
              Map.put(updated, "credentials", parse_credentials(json))
            _ ->
              updated
          end

        write(List.replace_at(buckets, idx, updated))
        :ok
    end
  end

  def delete(id) do
    buckets = list() |> Enum.reject(fn b -> b["id"] == id end)
    write(buckets)
  end

  def has_credentials?(id) do
    case get(id) do
      %{"credentials" => %{"client_email" => e}} when is_binary(e) -> true
      _ -> false
    end
  end

  # --- Private ---

  defp redact(bucket) do
    case bucket["credentials"] do
      %{"client_email" => email} ->
        Map.put(bucket, "credentials", %{
          "client_email" => email,
          "project_id" => bucket["credentials"]["project_id"],
          "_redacted" => true
        })

      _ ->
        Map.put(bucket, "credentials", nil)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_credentials(nil), do: nil
  defp parse_credentials(""), do: nil

  defp parse_credentials(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"client_email" => _, "private_key" => _} = creds} -> creds
      {:ok, _} -> nil
      {:error, _} -> nil
    end
  end

  defp parse_credentials(map) when is_map(map), do: map

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s-]+/, "_")
    |> String.trim("_")
  end

  defp read do
    case File.read(@path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, list} when is_list(list) -> list
          _ -> []
        end

      _ ->
        []
    end
  end

  defp write(buckets) do
    dir = Path.dirname(@path)
    File.mkdir_p!(dir)
    File.write!(@path, Jason.encode!(buckets, pretty: true))
  end
end

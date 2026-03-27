defmodule Naturecounts.Storage.GCSCache do
  @moduledoc """
  Local file cache for GCS videos. Downloads on first access,
  returns cached path on subsequent calls. Simple TTL-based cleanup.
  """

  require Logger

  @cache_dir "/tmp/gcs_cache"

  def ensure_local(bucket_config, object_path) do
    bucket = bucket_config["bucket"]
    local = cache_path(bucket, object_path)

    if File.exists?(local) do
      Logger.info("[GCSCache] Cache hit: #{object_path}")
      {:ok, local}
    else
      Logger.info("[GCSCache] Downloading #{object_path} to #{local}")

      case Naturecounts.Storage.GCS.download(bucket_config, object_path, local) do
        {:ok, _} ->
          Logger.info("[GCSCache] Downloaded #{object_path} (#{file_size_mb(local)} MB)")
          {:ok, local}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def cache_path(bucket, object_path) do
    safe_name = "#{bucket}_#{String.replace(object_path, "/", "_")}"
    Path.join(@cache_dir, safe_name)
  end

  def cleanup(max_age_hours \\ 24) do
    File.mkdir_p!(@cache_dir)
    cutoff = System.os_time(:second) - max_age_hours * 3600

    case File.ls(@cache_dir) do
      {:ok, files} ->
        Enum.each(files, fn file ->
          path = Path.join(@cache_dir, file)

          case File.stat(path) do
            {:ok, %{atime: atime}} ->
              atime_seconds = atime |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
              if atime_seconds < cutoff, do: File.rm(path)

            _ ->
              :ok
          end
        end)

      _ ->
        :ok
    end
  end

  defp file_size_mb(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> Float.round(size / 1_048_576, 1)
      _ -> 0
    end
  end
end

defmodule Naturecounts.Offline.MetricsStore do
  @moduledoc """
  Abstraction layer for per-video metrics storage.

  Stores metrics as JSON sidecar files: `video.mp4.metrics.json`.
  Falls back to reading the legacy monolithic `.metrics.json` for
  directories that haven't been migrated yet.
  """

  require Logger

  @sidecar_suffix ".metrics.json"
  @legacy_filename ".metrics.json"
  @legacy_migrated ".metrics.json.migrated"

  @doc """
  Read metrics for all videos in a directory.
  Returns `%{filename => metrics_map}`.

  Reads per-file sidecars first, then merges any remaining entries
  from the legacy monolithic `.metrics.json` (sidecar wins on conflict).
  """
  def read_dir(dir) do
    sidecars = read_sidecars(dir)
    legacy = read_legacy(dir)

    # Merge: sidecar entries take precedence
    Map.merge(legacy, sidecars)
  end

  @doc """
  Read metrics for a single video file.
  Returns the metrics map or nil.
  """
  def read_one(video_path) do
    sidecar_path = video_path <> @sidecar_suffix

    case File.read(sidecar_path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, metrics} -> metrics
          _ -> nil
        end

      _ ->
        # Fall back to legacy index
        dir = Path.dirname(video_path)
        name = Path.basename(video_path)
        legacy = read_legacy(dir)
        Map.get(legacy, name)
    end
  end

  @doc """
  Write metrics for a single video file as a sidecar.
  Adds `schema_version: 1` if not present.
  """
  def write_one(video_path, metrics) when is_map(metrics) do
    metrics = Map.put_new(metrics, "schema_version", 1)
    sidecar_path = video_path <> @sidecar_suffix
    tmp_path = sidecar_path <> ".tmp"

    case Jason.encode(metrics, pretty: true) do
      {:ok, json} ->
        File.write!(tmp_path, json)
        File.rename!(tmp_path, sidecar_path)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Migrate a directory from monolithic `.metrics.json` to per-file sidecars.
  Returns `{:ok, count}` with the number of sidecars written,
  or `{:error, reason}`.
  """
  def migrate_dir(dir) do
    legacy_path = Path.join(dir, @legacy_filename)

    case File.read(legacy_path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, index} when is_map(index) ->
            count =
              index
              |> Enum.reduce(0, fn {filename, metrics}, acc ->
                video_path = Path.join(dir, filename)
                sidecar_path = video_path <> @sidecar_suffix

                # Only write sidecar if it doesn't already exist
                unless File.exists?(sidecar_path) do
                  write_one(video_path, metrics)
                end

                acc + 1
              end)

            # Rename legacy file
            migrated_path = Path.join(dir, @legacy_migrated)
            File.rename(legacy_path, migrated_path)

            Logger.info("[MetricsStore] Migrated #{count} entries in #{dir}")
            {:ok, count}

          _ ->
            {:error, :invalid_json}
        end

      {:error, :enoent} ->
        {:ok, 0}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Check if a sidecar exists for a video path."
  def exists?(video_path) do
    File.exists?(video_path <> @sidecar_suffix)
  end

  # --- Private ---

  defp read_sidecars(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, @sidecar_suffix))
        |> Enum.reject(&(&1 == @legacy_filename or &1 == @legacy_migrated))
        |> Enum.reduce(%{}, fn sidecar_name, acc ->
          # "video.mp4.metrics.json" → "video.mp4"
          video_name = String.replace_suffix(sidecar_name, @sidecar_suffix, "")
          path = Path.join(dir, sidecar_name)

          case File.read(path) do
            {:ok, data} ->
              case Jason.decode(data) do
                {:ok, metrics} -> Map.put(acc, video_name, metrics)
                _ -> acc
              end

            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end

  defp read_legacy(dir) do
    legacy_path = Path.join(dir, @legacy_filename)

    case File.read(legacy_path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, index} when is_map(index) -> index
          _ -> %{}
        end

      _ ->
        %{}
    end
  end
end

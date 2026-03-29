defmodule Naturecounts.Offline.ScanMetricsWorker do
  @moduledoc """
  Oban worker for scanning video metrics.

  Dispatch flow:
    1. UI enqueues a single "dispatch" job
    2. Dispatch job lists videos, splits them into per-file jobs
    3. Each per-file job scans one video (isolated failure domain)

  One worker per CPU core. Each file is its own job so a crash
  only loses one file, and Oban retries it automatically.
  """
  use Oban.Worker,
    queue: :scanning,
    max_attempts: 3,
    unique: [period: 10, keys: [:mode, :directory, :file]]

  alias Naturecounts.Offline.MetricsScanner

  require Logger

  @video_extensions ~w(.mp4 .avi .mkv .mov .ts)

  # ── Dispatch: split directory into per-file jobs ──

  @impl true
  def perform(%Oban.Job{args: %{"mode" => "dispatch"} = args}) do
    directory = args["directory"]
    force = Map.get(args, "force", false)
    sample_frames = Map.get(args, "sample_frames", 60)

    videos = list_scannable_videos(directory, force)
    total = length(videos)

    Logger.info("[ScanMetrics] Dispatching #{total} file jobs for #{directory}")

    Phoenix.PubSub.broadcast(
      Naturecounts.PubSub,
      "scan:progress",
      {:scan_progress, directory, %{"done" => 0, "total" => total, "current" => "dispatching..."}}
    )

    for file <- videos do
      %{
        "mode" => "file",
        "directory" => directory,
        "file" => file,
        "force" => force,
        "sample_frames" => sample_frames,
        "total" => total
      }
      |> __MODULE__.new(priority: 2)
      |> Oban.insert!()
    end

    Logger.info("[ScanMetrics] Enqueued #{total} file jobs")
    :ok
  end

  # ── Single file scan ──

  def perform(%Oban.Job{args: %{"mode" => "file"} = args, attempt: attempt}) do
    directory = args["directory"]
    file = args["file"]
    sample_frames = Map.get(args, "sample_frames", 60)
    total = Map.get(args, "total", 0)

    video_path = Path.join(directory, file)
    Logger.info("[ScanMetrics] Scanning #{file} (attempt #{attempt}/3)")

    case MetricsScanner.scan_file(video_path, sample_frames: sample_frames) do
      {:ok, _result} ->
        Logger.info("[ScanMetrics] Done: #{file}")

        # Count completed sidecars to report progress
        done = count_sidecars(directory)

        Phoenix.PubSub.broadcast(
          Naturecounts.PubSub,
          "scan:progress",
          {:scan_progress, directory, %{"done" => done, "total" => total, "current" => file}}
        )

        # Notify batch complete so UI reloads entries
        Phoenix.PubSub.broadcast(
          Naturecounts.PubSub,
          "scan:progress",
          {:scan_batch_complete, directory, file, %{"scanned" => 1}}
        )

        # Check if all done
        if done >= total do
          Phoenix.PubSub.broadcast(
            Naturecounts.PubSub,
            "scan:progress",
            {:scan_complete, directory}
          )
        end

        :ok

      {:error, reason} ->
        Logger.error("[ScanMetrics] Failed #{file} (attempt #{attempt}/3): #{reason}")
        {:error, reason}
    end
  end

  # ── Legacy: batch mode (backwards compat with queued jobs) ──

  def perform(%Oban.Job{args: %{"mode" => "batch"} = args}) do
    directory = args["directory"]
    batch_files = args["files"]
    force = Map.get(args, "force", false)
    sample_frames = Map.get(args, "sample_frames", 5)
    batch_id = Map.get(args, "batch_id", "0")

    Logger.info("[ScanMetrics] Legacy batch #{batch_id}: #{length(batch_files)} files")

    case MetricsScanner.scan(directory,
           force: force,
           sample_frames: sample_frames,
           batch_files: batch_files,
           batch_id: batch_id
         ) do
      {:ok, result} ->
        Phoenix.PubSub.broadcast(
          Naturecounts.PubSub,
          "scan:progress",
          {:scan_batch_complete, directory, batch_id, result}
        )
        :ok

      {:error, reason} ->
        Logger.error("[ScanMetrics] Legacy batch #{batch_id} failed: #{reason}")
        {:error, reason}
    end
  end

  # ── Legacy: top-level directory job → re-dispatch as per-file ──

  def perform(%Oban.Job{args: %{"directory" => directory} = args})
      when not is_map_key(args, "mode") do
    # Convert old-style job into new dispatch
    Logger.info("[ScanMetrics] Converting legacy job to dispatch for #{directory}")

    %{
      "mode" => "dispatch",
      "directory" => directory,
      "force" => Map.get(args, "force", false),
      "sample_frames" => Map.get(args, "sample_frames", 60)
    }
    |> __MODULE__.new()
    |> Oban.insert!()

    :ok
  end

  # ── Helpers ──

  defp list_scannable_videos(directory, force) do
    case File.ls(directory) do
      {:ok, names} ->
        names
        |> Enum.filter(fn name ->
          path = Path.join(directory, name)
          ext = name |> Path.extname() |> String.downcase()
          File.regular?(path) and ext in @video_extensions
        end)
        |> Enum.reject(fn name ->
          not force and File.exists?(Path.join(directory, name) <> ".metrics.json")
        end)
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp count_sidecars(directory) do
    case File.ls(directory) do
      {:ok, names} ->
        Enum.count(names, &String.ends_with?(&1, ".metrics.json"))

      _ ->
        0
    end
  end
end

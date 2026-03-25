defmodule Naturecounts.Offline.ScanMetricsWorker do
  use Oban.Worker, queue: :scanning, max_attempts: 2, unique: [period: 30]

  alias Naturecounts.Offline.MetricsScanner

  require Logger

  @video_extensions ~w(.mp4 .avi .mkv .mov .ts)
  @default_batch_size 50
  @default_workers 8

  @impl true
  def perform(%Oban.Job{args: %{"mode" => "batch"} = args}) do
    directory = args["directory"]
    batch_files = args["files"]
    force = Map.get(args, "force", false)
    sample_frames = Map.get(args, "sample_frames", 5)
    batch_id = Map.get(args, "batch_id", "0")

    Logger.info("[ScanMetrics] Batch #{batch_id}: scanning #{length(batch_files)} files in #{directory}")

    case MetricsScanner.scan(directory,
           force: force,
           sample_frames: sample_frames,
           batch_files: batch_files,
           batch_id: batch_id
         ) do
      {:ok, result} ->
        Logger.info("[ScanMetrics] Batch #{batch_id} complete: #{result["scanned"]} scanned")

        Phoenix.PubSub.broadcast(
          Naturecounts.PubSub,
          "scan:progress",
          {:scan_batch_complete, directory, batch_id, result}
        )

        :ok

      {:error, reason} ->
        Logger.error("[ScanMetrics] Batch #{batch_id} failed: #{reason}")
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: %{"directory" => directory} = args}) do
    force = Map.get(args, "force", false)
    sample_frames = Map.get(args, "sample_frames", 5)
    parallel = Map.get(args, "parallel", false)
    num_workers = Map.get(args, "workers", @default_workers)
    batch_size = Map.get(args, "batch_size", @default_batch_size)

    if parallel do
      dispatch_batches(directory, force, sample_frames, num_workers, batch_size)
    else
      run_single(directory, force, sample_frames)
    end
  end

  defp run_single(directory, force, sample_frames) do
    Logger.info("[ScanMetrics] Starting single-worker scan of #{directory}")

    case MetricsScanner.scan(directory, force: force, sample_frames: sample_frames) do
      {:ok, result} ->
        Logger.info("[ScanMetrics] Complete: #{result["scanned"]} scanned")

        Phoenix.PubSub.broadcast(
          Naturecounts.PubSub,
          "scan:progress",
          {:scan_complete, directory}
        )

        :ok

      {:error, reason} ->
        Logger.error("[ScanMetrics] Failed: #{reason}")
        {:error, reason}
    end
  end

  defp dispatch_batches(directory, force, sample_frames, num_workers, batch_size) do
    Logger.info("[ScanMetrics] Dispatching parallel scan of #{directory} with #{num_workers} workers")

    # List all video files
    videos =
      case File.ls(directory) do
        {:ok, names} ->
          names
          |> Enum.filter(fn name ->
            path = Path.join(directory, name)
            ext = name |> Path.extname() |> String.downcase()
            File.regular?(path) and ext in @video_extensions
          end)
          |> Enum.sort()

        _ ->
          []
      end

    total = length(videos)
    Logger.info("[ScanMetrics] Found #{total} videos, splitting into batches of #{batch_size}")

    # Split into batches
    batches = Enum.chunk_every(videos, batch_size)

    Phoenix.PubSub.broadcast(
      Naturecounts.PubSub,
      "scan:progress",
      {:scan_progress, directory, %{"done" => 0, "total" => total, "current" => "dispatching #{length(batches)} batches..."}}
    )

    # Enqueue batch jobs
    for {batch, idx} <- Enum.with_index(batches) do
      %{
        "mode" => "batch",
        "directory" => directory,
        "files" => batch,
        "force" => force,
        "sample_frames" => sample_frames,
        "batch_id" => "#{idx}"
      }
      |> __MODULE__.new()
      |> Oban.insert!()
    end

    Logger.info("[ScanMetrics] Enqueued #{length(batches)} batch jobs for #{total} videos")
    :ok
  end
end

defmodule Naturecounts.Offline.ScanMetricsWorker do
  use Oban.Worker, queue: :video_processing, max_attempts: 1, unique: [period: 60]

  alias Naturecounts.Offline.MetricsScanner

  require Logger

  @impl true
  def perform(%Oban.Job{args: %{"directory" => directory} = args}) do
    force = Map.get(args, "force", false)
    sample_frames = Map.get(args, "sample_frames", 5)

    Logger.info("[ScanMetrics] Starting scan of #{directory}")

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
end

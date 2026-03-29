defmodule Naturecounts.Offline.FixTimestampsWorker do
  @moduledoc """
  Oban worker that remuxes MP4/MOV files in-place to normalize PTS timestamps.
  Videos from IP cameras often have non-zero start_time which prevents browser seeking.
  Uses stream copy (no re-encoding) — fast even for large files.

  Dispatch flow:
    1. UI enqueues a "dispatch" job for a directory
    2. Dispatch job lists videos, enqueues per-file jobs
    3. Each per-file job checks + fixes one video (parallel across queue workers)
  """
  use Oban.Worker,
    queue: :scanning,
    max_attempts: 2,
    unique: [period: 10, keys: [:mode, :directory, :file]]

  require Logger

  @video_extensions ~w(.mp4 .mov)

  # ── Dispatch: split directory into per-file jobs ──

  @impl true
  def perform(%Oban.Job{args: %{"mode" => "dispatch"} = args}) do
    directory = args["directory"]
    files = list_videos(directory)
    total = length(files)

    Logger.info("[FixTimestamps] Dispatching #{total} file jobs for #{directory}")

    Phoenix.PubSub.broadcast(
      Naturecounts.PubSub,
      "scan:progress",
      {:scan_progress, directory, %{"done" => 0, "total" => total, "current" => "dispatching..."}}
    )

    for file <- files do
      %{
        "mode" => "file",
        "directory" => directory,
        "file" => file,
        "total" => total
      }
      |> __MODULE__.new(priority: 2)
      |> Oban.insert!()
    end

    Logger.info("[FixTimestamps] Enqueued #{total} file jobs")
    :ok
  end

  # ── Single file fix ──

  def perform(%Oban.Job{args: %{"mode" => "file"} = args}) do
    directory = args["directory"]
    file = args["file"]
    path = Path.join(directory, file)

    case fix_file(path) do
      :fixed ->
        Logger.info("[FixTimestamps] Fixed #{file}")
        Naturecounts.Cache.invalidate_group(:file_browser)
        :ok

      :ok ->
        :ok

      :error ->
        :ok
    end
  end

  defp list_videos(directory) do
    case File.ls(directory) do
      {:ok, names} ->
        names
        |> Enum.filter(fn name ->
          ext = name |> Path.extname() |> String.downcase()
          ext in @video_extensions
        end)
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp fix_file(path) do
    case get_start_time(path) do
      {:ok, start_time} when start_time > 0.5 ->
        remux_in_place(path)

      {:ok, _} ->
        :ok

      :error ->
        :error
    end
  end

  defp get_start_time(path) do
    case System.cmd(ffprobe_path(), [
           "-v", "error",
           "-select_streams", "v:0",
           "-show_entries", "stream=start_time",
           "-of", "csv=p=0",
           path
         ], stderr_to_stdout: true) do
      {output, 0} ->
        case Float.parse(String.trim(output)) do
          {val, _} -> {:ok, val}
          :error -> {:ok, 0.0}
        end

      _ ->
        :error
    end
  end

  defp remux_in_place(path) do
    ext = Path.extname(path)
    tmp = String.replace_suffix(path, ext, ".fixing#{ext}")

    {output, exit_code} =
      System.cmd(ffmpeg_path(), [
        "-i", path,
        "-c", "copy",
        "-movflags", "+faststart",
        "-avoid_negative_ts", "make_zero",
        "-fflags", "+genpts",
        "-y",
        tmp
      ], stderr_to_stdout: true)

    if exit_code == 0 and File.exists?(tmp) do
      File.rename!(tmp, path)
      :fixed
    else
      File.rm(tmp)
      error_line = output |> String.split("\n") |> Enum.filter(&String.contains?(&1, "Error")) |> Enum.join("; ")
      Logger.warning("[FixTimestamps] Failed to fix #{Path.basename(path)}: exit=#{exit_code} #{error_line}")
      :error
    end
  end

  defp ffprobe_path, do: find_executable("ffprobe")
  defp ffmpeg_path, do: find_executable("ffmpeg")

  defp find_executable(name) do
    case System.find_executable(name) do
      nil ->
        Path.wildcard("/app/deps/bundlex/**/bin/#{name}") |> List.first() || name

      path ->
        path
    end
  end
end

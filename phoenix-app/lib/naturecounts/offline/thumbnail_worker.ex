defmodule Naturecounts.Offline.ThumbnailWorker do
  @moduledoc """
  Oban worker that extracts evenly-spaced thumbnail frames from videos.

  Dispatch flow:
    1. UI enqueues a "dispatch" job for a directory
    2. Dispatch job lists videos, enqueues per-file jobs
    3. Each per-file job extracts N thumbnails via ffmpeg

  Thumbnails are stored in a `.thumbs/<video_name>/` subfolder:
    /videos/.thumbs/cam1.mp4/001.jpg
    /videos/.thumbs/cam1.mp4/002.jpg
    ...
  """
  use Oban.Worker,
    queue: :scanning,
    max_attempts: 2,
    unique: [period: 10, keys: [:mode, :directory, :file]]

  require Logger

  @video_extensions ~w(.mp4 .avi .mkv .mov .ts)
  @default_count 8
  @thumb_width 320
  @thumbs_dir ".thumbs"

  # ── Dispatch ──

  @impl true
  def perform(%Oban.Job{args: %{"mode" => "dispatch"} = args}) do
    directory = args["directory"]
    force = Map.get(args, "force", false)
    count = Map.get(args, "count", @default_count)

    files = list_videos(directory, force)
    total = length(files)

    Logger.info("[Thumbnails] Dispatching #{total} file jobs for #{directory}")

    Phoenix.PubSub.broadcast(
      Naturecounts.PubSub,
      "scan:progress",
      {:scan_progress, directory, %{"done" => 0, "total" => total, "current" => "thumbnails..."}}
    )

    for file <- files do
      %{
        "mode" => "file",
        "directory" => directory,
        "file" => file,
        "count" => count,
        "total" => total
      }
      |> __MODULE__.new(priority: 2)
      |> Oban.insert!()
    end

    :ok
  end

  # ── Single file ──

  def perform(%Oban.Job{args: %{"mode" => "file"} = args}) do
    directory = args["directory"]
    file = args["file"]
    count = Map.get(args, "count", @default_count)
    total = Map.get(args, "total", 0)

    video_path = Path.join(directory, file)

    case extract_thumbnails(video_path, count) do
      :ok ->
        Logger.info("[Thumbnails] Done: #{file}")
        done = count_completed(directory)

        Phoenix.PubSub.broadcast(
          Naturecounts.PubSub,
          "scan:progress",
          {:scan_progress, directory, %{"done" => done, "total" => total, "current" => file}}
        )

        if done >= total do
          Phoenix.PubSub.broadcast(
            Naturecounts.PubSub,
            "scan:progress",
            {:scan_complete, directory}
          )
        end

        :ok

      {:error, reason} ->
        Logger.error("[Thumbnails] Failed #{file}: #{reason}")
        {:error, reason}
    end
  end

  # ── Public API ──

  @doc "Returns the thumbnail directory for a given video path."
  def thumb_dir(video_path) do
    dir = Path.dirname(video_path)
    name = Path.basename(video_path)
    Path.join([dir, @thumbs_dir, name])
  end

  @doc "Lists thumbnail paths for a video, sorted."
  def list_thumbs(video_path) do
    dir = thumb_dir(video_path)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".jpg"))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))

      _ ->
        []
    end
  end

  @doc "Returns true if thumbnails already exist for this video."
  def has_thumbs?(video_path) do
    dir = thumb_dir(video_path)
    File.dir?(dir) and match?({:ok, [_ | _]}, File.ls(dir))
  end

  # ── Extraction ──

  defp extract_thumbnails(video_path, count) do
    duration = get_duration(video_path)

    if duration == nil or duration <= 0 do
      {:error, "could not determine duration"}
    else
      out_dir = thumb_dir(video_path)
      File.mkdir_p!(out_dir)

      # Evenly spaced across middle 90%
      start_t = duration * 0.05
      end_t = duration * 0.95
      span = end_t - start_t

      errors =
        for i <- 0..(count - 1), reduce: [] do
          acc ->
            t = start_t + i * span / max(count - 1, 1)
            out_path = Path.join(out_dir, String.pad_leading("#{i + 1}", 3, "0") <> ".jpg")

            case extract_frame(video_path, t, out_path) do
              :ok -> acc
              {:error, reason} -> [reason | acc]
            end
        end

      if errors == [], do: :ok, else: {:error, Enum.join(errors, "; ")}
    end
  end

  defp extract_frame(video_path, time_s, out_path) do
    args = [
      "-ss", Float.to_string(Float.round(time_s, 2)),
      "-i", video_path,
      "-vframes", "1",
      "-vf", "scale=#{@thumb_width}:-1",
      "-q:v", "4",
      "-y",
      out_path
    ]

    case System.cmd(ffmpeg_path(), args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, "ffmpeg exit #{code}: #{String.slice(output, -200, 200)}"}
    end
  end

  defp get_duration(video_path) do
    args = [
      "-v", "error",
      "-select_streams", "v:0",
      "-show_entries", "format=duration",
      "-of", "csv=p=0",
      video_path
    ]

    case System.cmd(ffprobe_path(), args, stderr_to_stdout: true) do
      {output, 0} ->
        case Float.parse(String.trim(output)) do
          {val, _} -> val
          :error -> nil
        end

      _ ->
        nil
    end
  end

  # ── Helpers ──

  defp list_videos(directory, force) do
    case File.ls(directory) do
      {:ok, names} ->
        names
        |> Enum.filter(fn name ->
          ext = name |> Path.extname() |> String.downcase()
          path = Path.join(directory, name)
          File.regular?(path) and ext in @video_extensions
        end)
        |> Enum.reject(fn name ->
          not force and has_thumbs?(Path.join(directory, name))
        end)
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp count_completed(directory) do
    thumbs_path = Path.join(directory, @thumbs_dir)

    case File.ls(thumbs_path) do
      {:ok, names} -> length(names)
      _ -> 0
    end
  end

  defp ffmpeg_path, do: find_executable("ffmpeg")
  defp ffprobe_path, do: find_executable("ffprobe")

  defp find_executable(name) do
    case System.find_executable(name) do
      nil ->
        Path.wildcard("/app/deps/bundlex/**/bin/#{name}") |> List.first() || name

      path ->
        path
    end
  end
end

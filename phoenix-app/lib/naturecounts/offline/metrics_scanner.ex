defmodule Naturecounts.Offline.MetricsScanner do
  @moduledoc """
  Fast video metrics scanner. Samples a few frames per video,
  runs YOLO detection, and writes a .metrics.json index file.
  """

  require Logger

  @python_code """
  import cv2
  import numpy as np
  import json
  import os
  import time
  from datetime import datetime, timezone
  from ultralytics import YOLO

  if isinstance(model_path, bytes):
      model_path = model_path.decode("utf-8")
  if isinstance(directory, bytes):
      directory = directory.decode("utf-8")
  if isinstance(progress_file, bytes):
      progress_file = progress_file.decode("utf-8")
  if isinstance(skip_filenames, bytes):
      skip_filenames = skip_filenames.decode("utf-8")
  if isinstance(cancel_file, bytes):
      cancel_file = cancel_file.decode("utf-8")
  if isinstance(batch_files, bytes):
      batch_files = batch_files.decode("utf-8")

  import fcntl

  skip_set = set(json.loads(skip_filenames))
  batch_list = json.loads(batch_files) if batch_files else []

  VIDEO_EXTENSIONS = {".mp4", ".avi", ".mkv", ".mov", ".ts"}

  index_path = os.path.join(directory, ".metrics.json")
  lock_path = index_path + ".lock"

  def read_index():
      if os.path.exists(index_path):
          with open(index_path) as f:
              return json.load(f)
      return {}

  def write_index(data):
      lock_fd = open(lock_path, "w")
      fcntl.flock(lock_fd, fcntl.LOCK_EX)
      try:
          # Re-read to merge with any concurrent writes
          current = {}
          if os.path.exists(index_path):
              with open(index_path) as f:
                  current = json.load(f)
          current.update(data)
          with open(index_path, "w") as f:
              json.dump(current, f, indent=2)
      finally:
          fcntl.flock(lock_fd, fcntl.LOCK_UN)
          lock_fd.close()

  # Load existing index for skip check
  existing = read_index() if not force_rescan else {}

  # Find videos to scan
  if batch_list:
      all_videos = batch_list
  else:
      all_videos = sorted([
          f for f in os.listdir(directory)
          if os.path.isfile(os.path.join(directory, f))
          and os.path.splitext(f)[1].lower() in VIDEO_EXTENSIONS
      ])

  to_scan = [v for v in all_videos if v not in skip_set and (v not in existing or force_rescan)]
  total_to_scan = len(to_scan)

  if total_to_scan > 0:
      model = YOLO(model_path)

      for idx, filename in enumerate(to_scan):
          video_path = os.path.join(directory, filename)
          cap = cv2.VideoCapture(video_path)

          if not cap.isOpened():
              existing[filename] = {"error": "could not read video"}
              cap.release()
              # Write progress
              with open(progress_file, "w") as pf:
                  json.dump({"done": idx + 1, "total": total_to_scan, "current": filename}, pf)
              continue

          total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
          fps_val = cap.get(cv2.CAP_PROP_FPS)
          width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
          height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
          duration = total_frames / fps_val if fps_val > 0 else 0

          # Sample frames
          start_f = int(total_frames * 0.05)
          end_f = int(total_frames * 0.95)
          if end_f <= start_f:
              start_f, end_f = 0, max(total_frames - 1, 0)

          n = sample_frames
          positions = [start_f + i * (end_f - start_f) // max(n - 1, 1) for i in range(n)]

          frames = []
          frame_positions = []
          for pos in positions:
              cap.set(cv2.CAP_PROP_POS_FRAMES, pos)
              ret, frame = cap.read()
              if ret:
                  frames.append(frame)
                  frame_positions.append(pos)
          cap.release()

          all_areas = []
          total_detections = 0
          brightness_values = []
          contrast_values = []
          grays = []
          per_frame_detections = []

          for frame in frames:
              gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
              grays.append(gray)
              brightness_values.append(float(np.mean(gray)))
              contrast_values.append(float(np.std(gray)))

              frame_det_count = 0
              results = model(frame, verbose=False, imgsz=640, conf=0.15)
              for r in results:
                  boxes = r.boxes
                  if boxes is not None and len(boxes) > 0:
                      frame_det_count += len(boxes)
                      for box in boxes.xyxy.cpu().numpy():
                          x1, y1, x2, y2 = box[:4]
                          area = int((x2 - x1) * (y2 - y1))
                          all_areas.append(area)
              total_detections += frame_det_count
              per_frame_detections.append(frame_det_count)

          # Motion score: mean absolute difference between consecutive frames
          motion_diffs = []
          for i in range(1, len(grays)):
              diff = cv2.absdiff(grays[i - 1], grays[i])
              motion_diffs.append(float(np.mean(diff)))

          n_sampled = len(frames)
          avg_det = total_detections / n_sampled if n_sampled > 0 else 0
          avg_brightness = round(sum(brightness_values) / len(brightness_values), 1) if brightness_values else 0
          avg_contrast = round(sum(contrast_values) / len(contrast_values), 1) if contrast_values else 0
          motion_score = round(sum(motion_diffs) / len(motion_diffs), 2) if motion_diffs else 0

          # Per-sample temporal data
          samples = []
          for si in range(n_sampled):
              ts = round(frame_positions[si] / fps_val, 1) if fps_val > 0 else 0
              mot = motion_diffs[si - 1] if si > 0 and si - 1 < len(motion_diffs) else 0
              samples.append({
                  "t": ts,
                  "det": per_frame_detections[si],
                  "bright": round(brightness_values[si], 1),
                  "contrast": round(contrast_values[si], 1),
                  "motion": round(mot, 2),
              })

          existing[filename] = {
              "total_frames": total_frames,
              "fps": round(fps_val, 2),
              "duration_s": round(duration, 1),
              "resolution": f"{width}x{height}",
              "sampled_frames": n_sampled,
              "total_detections": total_detections,
              "avg_detections_per_frame": round(avg_det, 1),
              "avg_brightness": avg_brightness,
              "contrast": avg_contrast,
              "motion_score": motion_score,
              "scanned_at": datetime.now(timezone.utc).isoformat(),
              "samples": samples,
              "bbox_areas": {
                  "count": len(all_areas),
                  "min": min(all_areas) if all_areas else 0,
                  "max": max(all_areas) if all_areas else 0,
                  "mean": round(sum(all_areas) / len(all_areas)) if all_areas else 0,
              },
          }

          # Write incrementally with file lock
          write_index({filename: existing[filename]})

          # Write progress
          with open(progress_file, "w") as pf:
              json.dump({"done": idx + 1, "total": total_to_scan, "current": filename}, pf)

          # Check for cancellation
          if os.path.exists(cancel_file):
              os.remove(cancel_file)
              break

  scan_result = json.dumps({"scanned": total_to_scan, "total": len(all_videos), "skipped": len(all_videos) - total_to_scan})
  """

  def scan(directory, opts \\ []) do
    import Ecto.Query
    alias Naturecounts.Repo
    alias Naturecounts.Offline.Video

    model_path = System.get_env("YOLO_MODEL_PATH", "/models/cfd-yolov12x-1.00.onnx")
    sample_frames = Keyword.get(opts, :sample_frames, 5)
    force = Keyword.get(opts, :force, false)
    batch_files = Keyword.get(opts, :batch_files, [])
    batch_id = Keyword.get(opts, :batch_id, "0")
    progress_callback = Keyword.get(opts, :progress_callback)

    # Get filenames already fully processed in DB — skip these
    processed_filenames =
      Video
      |> where([v], v.status == "completed" and like(v.path, ^"#{directory}/%"))
      |> select([v], v.path)
      |> Repo.all()
      |> Enum.map(&Path.basename/1)

    progress_file = Path.join(System.tmp_dir!(), "scan_progress_#{batch_id}.json")
    cancel_file = Path.join(System.tmp_dir!(), "scan_cancel")

    # Clear stale state (only clear cancel file for batch 0)
    if batch_id == "0", do: File.rm(cancel_file)
    File.rm(progress_file)

    globals = %{
      "directory" => directory,
      "model_path" => model_path,
      "sample_frames" => sample_frames,
      "force_rescan" => force,
      "progress_file" => progress_file,
      "cancel_file" => cancel_file,
      "skip_filenames" => Jason.encode!(processed_filenames),
      "batch_files" => Jason.encode!(batch_files)
    }

    {:ok, poller_pid} = Task.start(fn -> poll_progress(progress_file, directory) end)

    Logger.info("[MetricsScanner] Scanning #{directory}")

    try do
      {_result, updated_globals} = Pythonx.eval(@python_code, globals)

      Process.exit(poller_pid, :normal)
      File.rm(progress_file)

      result_json = Pythonx.decode(updated_globals["scan_result"])

      case Jason.decode(result_json) do
        {:ok, result} ->
          Logger.info("[MetricsScanner] Done: #{result["scanned"]} scanned, #{result["skipped"]} skipped")
          {:ok, result}

        {:error, reason} ->
          {:error, "Failed to parse scan results: #{inspect(reason)}"}
      end
    rescue
      e ->
        Process.exit(poller_pid, :normal)
        File.rm(progress_file)
        Logger.error("[MetricsScanner] Failed: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  defp poll_progress(progress_file, directory) do
    case File.read(progress_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} ->
            Phoenix.PubSub.broadcast(
              Naturecounts.PubSub,
              "scan:progress",
              {:scan_progress, directory, data}
            )
          _ -> :ok
        end
      _ -> :ok
    end

    Process.sleep(1500)
    poll_progress(progress_file, directory)
  end
end

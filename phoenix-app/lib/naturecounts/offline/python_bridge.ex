defmodule Naturecounts.Offline.PythonBridge do
  @moduledoc """
  Runs YOLO detection + ByteTrack tracking via Pythonx (embedded Python).
  Also provides Fishial BEiT v2 classification for species identification.
  """

  require Logger

  @python_code """
  import cv2
  import numpy as np
  import supervision as sv
  import base64
  import json
  import os
  import sys
  from collections import defaultdict

  # Pythonx passes Elixir strings as bytes — decode to str
  if isinstance(model_path, bytes):
      model_path = model_path.decode("utf-8")
  if isinstance(video_path, bytes):
      video_path = video_path.decode("utf-8")
  if isinstance(progress_file, bytes):
      progress_file = progress_file.decode("utf-8")
  if isinstance(priv_python_dir, bytes):
      priv_python_dir = priv_python_dir.decode("utf-8")

  # Add priv/python to sys.path so we can import detectors module
  if priv_python_dir not in sys.path:
      sys.path.insert(0, priv_python_dir)

  from detectors import create_detector

  def sharpness(frame, bbox):
      # Laplacian variance of the cropped region - higher = sharper
      x1, y1, x2, y2 = [int(v) for v in bbox]
      fh, fw = frame.shape[:2]
      x1, y1 = max(0, x1), max(0, y1)
      x2, y2 = min(fw, x2), min(fh, y2)
      crop = frame[y1:y2, x1:x2]
      if crop.size == 0:
          return 0.0
      gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
      return float(cv2.Laplacian(gray, cv2.CV_64F).var())

  def crop_and_encode(frame, bbox, quality=85):
      x1, y1, x2, y2 = [int(v) for v in bbox]
      fh, fw = frame.shape[:2]
      x1, y1 = max(0, x1), max(0, y1)
      x2, y2 = min(fw, x2), min(fh, y2)
      crop = frame[y1:y2, x1:x2]
      if crop.size == 0:
          return None
      _, buf = cv2.imencode(".jpg", crop, [cv2.IMWRITE_JPEG_QUALITY, quality])
      return base64.b64encode(buf).decode("ascii")

  def write_progress(pct, frame_idx, total_frames, num_tracks, num_detections):
      with open(progress_file, "w") as f:
          json.dump({"pct": pct, "frame": frame_idx, "total_frames": total_frames,
                      "tracks": num_tracks, "detections": num_detections}, f)

  # Check CUDA availability
  import torch
  cuda_available = torch.cuda.is_available()
  cuda_device = torch.cuda.get_device_name(0) if cuda_available else "none"
  print(f"[PythonBridge] CUDA available: {cuda_available}, device: {cuda_device}", flush=True)

  # Load model
  write_progress(0, 0, 0, 0, 0)
  device = "cuda:0" if cuda_available else "cpu"
  model = create_detector(model_path, device)

  # Open video
  cap = cv2.VideoCapture(video_path)
  if not cap.isOpened():
      raise RuntimeError(f"Cannot open video: {video_path}")

  video_fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
  total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
  step = max(1, int(video_fps / fps))

  # ByteTrack tracker
  tracker = sv.ByteTrack(
      track_activation_threshold=conf_threshold,
      minimum_matching_threshold=0.8,
      frame_rate=int(fps),
  )

  track_state = defaultdict(lambda: {
      "first_frame": None, "last_frame": None, "frame_count": 0,
      "best_confidence": 0.0, "best_bbox_area": 0,
      "best_sharpness": 0.0, "best_score": 0.0,
      "best_crop": None, "best_bbox": None,
  })

  last_pct = -1
  frame_idx = 0
  total_detections = 0

  while True:
      ret, frame = cap.read()
      if not ret:
          break

      if frame_idx % step == 0:
          # Run detection
          xyxy, confs, class_ids = model.predict(frame, imgsz=imgsz, conf=conf_threshold)

          if len(xyxy) > 0:
              total_detections += len(xyxy)

              detections = sv.Detections(
                  xyxy=xyxy,
                  confidence=confs,
                  class_id=class_ids,
              )
              detections = tracker.update_with_detections(detections)

              for i in range(len(detections)):
                  tid = int(detections.tracker_id[i])
                  bbox = detections.xyxy[i]
                  conf_val = float(detections.confidence[i])
                  x1, y1, x2, y2 = bbox
                  area = int((x2 - x1) * (y2 - y1))

                  state = track_state[tid]
                  if state["first_frame"] is None:
                      state["first_frame"] = frame_idx
                  state["last_frame"] = frame_idx
                  state["frame_count"] += 1

                  sharp = sharpness(frame, bbox)
                  # Composite score: area * confidence * sqrt(sharpness)
                  # sqrt dampens sharpness so it doesn't dominate over size
                  score = area * conf_val * (sharp ** 0.5 + 1)
                  if score > state["best_score"]:
                      state["best_score"] = score
                      state["best_confidence"] = conf_val
                      state["best_bbox_area"] = area
                      state["best_sharpness"] = sharp
                      state["best_bbox"] = [float(x1), float(y1), float(x2), float(y2)]
                      state["best_crop"] = crop_and_encode(frame, bbox)

      if total_frames > 0:
          pct = int((frame_idx / total_frames) * 100)
          if pct > last_pct:
              write_progress(pct, frame_idx, total_frames, len(track_state), total_detections)
              last_pct = pct

      frame_idx += 1

  cap.release()
  write_progress(100, frame_idx, total_frames, len(track_state), total_detections)

  # Build results
  results = []
  for tid, state in sorted(track_state.items()):
      results.append({
          "track_id": tid,
          "first_frame": state["first_frame"],
          "last_frame": state["last_frame"],
          "frame_count": state["frame_count"],
          "best_confidence": round(state["best_confidence"], 4),
          "best_sharpness": round(state["best_sharpness"], 1),
          "best_bbox_area": state["best_bbox_area"],
          "bbox": state["best_bbox"],
          "crop_b64": state["best_crop"],
      })

  results_json = json.dumps(results)
  """

  @doc """
  Run detection on a video file. Accepts an optional `progress_callback` function
  that receives `%{pct: int, frame: int, total_frames: int, tracks: int, detections: int}`.
  """
  def run(video_path, profile, opts \\ []) do
    model_path = model_path_for(profile)

    unless File.exists?(video_path) do
      {:error, "Video file not found: #{video_path}"}
    else
      run_detection(video_path, model_path, profile, opts[:progress_callback])
    end
  end

  defp run_detection(video_path, model_path, profile, progress_callback) do
    Logger.info("[PythonBridge] Loading model #{model_path}")
    Logger.info("[PythonBridge] Config: fps=#{profile.fps}, imgsz=#{profile.imgsz}, conf=#{profile.detection_threshold}, min_area=#{profile.min_bbox_area}")

    progress_file = Path.join(System.tmp_dir!(), "yolo_progress_#{:erlang.unique_integer([:positive])}.json")

    globals = %{
      "video_path" => video_path,
      "model_path" => model_path,
      "priv_python_dir" => priv_python_dir(),
      "fps" => profile.fps,
      "imgsz" => profile.imgsz,
      "conf_threshold" => profile.detection_threshold,
      "min_bbox_area" => profile.min_bbox_area,
      "progress_file" => progress_file
    }

    # Start polling progress file
    poller_pid =
      if progress_callback do
        {:ok, pid} = Task.start(fn -> poll_progress(progress_file, progress_callback) end)
        pid
      end

    start_time = System.monotonic_time(:millisecond)

    try do
      {_result, updated_globals} = Pythonx.eval(@python_code, globals)
      elapsed = System.monotonic_time(:millisecond) - start_time

      if poller_pid, do: Process.exit(poller_pid, :normal)
      File.rm(progress_file)

      results_json = Pythonx.decode(updated_globals["results_json"])

      case Jason.decode(results_json) do
        {:ok, tracks} ->
          with_crops = Enum.count(tracks, & &1["crop_b64"])
          Logger.info("[PythonBridge] Detection complete in #{Float.round(elapsed / 1000, 1)}s: #{length(tracks)} tracks (#{with_crops} with crops)")
          {:ok, tracks}

        {:error, reason} ->
          Logger.error("[PythonBridge] Failed to parse JSON results: #{inspect(reason)}")
          {:error, "Failed to parse detection results: #{inspect(reason)}"}
      end
    rescue
      e ->
        elapsed = System.monotonic_time(:millisecond) - start_time
        if poller_pid, do: Process.exit(poller_pid, :normal)
        File.rm(progress_file)
        Logger.error("[PythonBridge] Python crashed after #{Float.round(elapsed / 1000, 1)}s: #{Exception.message(e)}")
        {:error, "Python detection failed: #{Exception.message(e)}"}
    end
  end

  defp poll_progress(progress_file, callback) do
    case File.read(progress_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> callback.(data)
          _ -> :ok
        end

      _ ->
        :ok
    end

    Process.sleep(1000)
    poll_progress(progress_file, callback)
  end

  defp model_path_for(profile) do
    case Map.get(profile, :detector_model, :default) do
      :rfdetr_nano ->
        System.get_env("RFDETR_MODEL_PATH", "/models/community-fish-detector-2026.02.02-rf-detr-nano-640.pth")

      :yolov12x ->
        System.get_env("YOLO_MODEL_PATH", "/models/cfd-yolov12x-1.00.pt")

      _ ->
        System.get_env("DETECTOR_MODEL_PATH",
          System.get_env("YOLO_MODEL_PATH", "/models/cfd-yolov12x-1.00.pt"))
    end
  end

  defp priv_python_dir do
    Application.app_dir(:naturecounts, "priv/python")
  end

  # ---------------------------------------------------------------------------
  # Fishial classification (uses their bundled inference.py EmbeddingClassifier)
  # ---------------------------------------------------------------------------

  @fishial_code """
  import sys
  import numpy as np
  import cv2
  import base64
  import json

  # Pythonx passes Elixir strings as bytes
  if isinstance(fishial_dir, bytes):
      fishial_dir = fishial_dir.decode("utf-8")
  if isinstance(crops_json, bytes):
      crops_json = crops_json.decode("utf-8")

  # Lazy-load classifier (cached across calls via globals)
  if "fishial_classifier" not in dir() or fishial_classifier is None:
      import os
      import torch

      # Add fishial dir to sys.path so we can import inference.py
      if fishial_dir not in sys.path:
          sys.path.insert(0, fishial_dir)

      from inference import EmbeddingClassifier

      cuda_available = torch.cuda.is_available()
      device = "cuda:0" if cuda_available else "cpu"
      print(f"[Fishial] Loading model from {fishial_dir}, device={device}", flush=True)

      config = {
          "log_level": "INFO",
          "dataset": {"path": os.path.join(fishial_dir, "database.pt")},
          "model": {
              "checkpoint_path": os.path.join(fishial_dir, "model.ckpt"),
              "backbone_model_name": "beitv2_base_patch16_224.in1k_ft_in22k_in1k",
              "embedding_dim": 512,
              "num_classes": 775,
              "arcface_s": 64.0,
              "arcface_m": 0.2,
              "pooling_type": "attention",
              "device": device,
          },
          "use_knn": True,
      }

      fishial_classifier = EmbeddingClassifier(config)
      fishial_classifier.warmup(num_iterations=3)
      info = fishial_classifier.get_model_info()
      print(f"[Fishial] Model ready: {info.get('num_classes', '?')} classes", flush=True)

  # Parse input crops
  crops_list = json.loads(crops_json)

  results = []

  if len(crops_list) > 0:
      # Decode crops to numpy arrays
      images = []
      valid_indices = []
      for i, item in enumerate(crops_list):
          try:
              crop_bytes = base64.b64decode(item["crop_b64"])
              nparr = np.frombuffer(crop_bytes, np.uint8)
              img = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
              if img is None:
                  continue
              img_rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
              images.append(img_rgb)
              valid_indices.append(i)
          except Exception as e:
              print(f"[Fishial] Failed to decode crop for track {item.get('track_id')}: {e}", flush=True)

      if len(images) > 0:
          # Batch inference using Fishial's EmbeddingClassifier
          batch_results = fishial_classifier(images)

          for j, idx in enumerate(valid_indices):
              preds = batch_results[j]
              if preds and len(preds) > 0:
                  top = preds[0]
                  results.append({
                      "track_id": crops_list[idx]["track_id"],
                      "species": top.name,
                      "confidence": round(float(top.accuracy), 4),
                  })
              else:
                  results.append({
                      "track_id": crops_list[idx]["track_id"],
                      "species": "unidentified",
                      "confidence": 0.0,
                  })

  fishial_results_json = json.dumps(results)
  """

  @doc """
  Classify a list of crops using the Fishial EmbeddingClassifier.
  Input: list of %{"track_id" => id, "crop_b64" => base64_jpeg}
  Returns {:ok, [%{"track_id" => id, "species" => name, "confidence" => float}]} or {:error, reason}
  """
  def classify_fishial(crops, opts \\ []) do
    fishial_dir = Keyword.get(opts, :fishial_dir, fishial_dir())

    unless File.exists?(Path.join(fishial_dir, "model.ckpt")) do
      {:error, "Fishial model not found in #{fishial_dir}"}
    else
      run_fishial_classification(crops, fishial_dir)
    end
  end

  defp run_fishial_classification(crops, fishial_dir) do
    Logger.info("[Fishial] Classifying #{length(crops)} crops")
    start_time = System.monotonic_time(:millisecond)

    crops_json = Jason.encode!(crops)

    globals = %{
      "fishial_dir" => fishial_dir,
      "crops_json" => crops_json
    }

    try do
      {_result, updated_globals} = Pythonx.eval(@fishial_code, globals)
      elapsed = System.monotonic_time(:millisecond) - start_time

      results_json = Pythonx.decode(updated_globals["fishial_results_json"])

      case Jason.decode(results_json) do
        {:ok, results} ->
          Logger.info("[Fishial] Classification complete in #{Float.round(elapsed / 1000, 1)}s: #{length(results)} crops classified")
          {:ok, results}

        {:error, reason} ->
          Logger.error("[Fishial] Failed to parse results: #{inspect(reason)}")
          {:error, "Failed to parse Fishial results"}
      end
    rescue
      e ->
        elapsed = System.monotonic_time(:millisecond) - start_time
        Logger.error("[Fishial] Python crashed after #{Float.round(elapsed / 1000, 1)}s: #{Exception.message(e)}")
        {:error, "Fishial classification failed: #{Exception.message(e)}"}
    end
  end

  defp fishial_dir do
    System.get_env("FISHIAL_MODEL_DIR", "/models/fishial")
  end
end

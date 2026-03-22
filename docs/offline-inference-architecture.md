# Offline Inference Architecture

## Purpose

A separate pipeline from the real-time DeepStream system, designed for:

- Maximum accuracy (no real-time constraints)
- Processing arbitrary video files (not just RTSP streams)
- Species identification using heavy models (VLMs, LLMs)
- Producing validated counts and species inventories

## Real-time vs Offline

| | Real-time (DeepStream C++) | Offline |
|---|---|---|
| **Goal** | Live monitoring + approximate counts | Accurate species inventory |
| **Speed** | 30fps, 3 cameras simultaneously | As slow as needed per frame |
| **Detection** | YOLOv12x @ 640px, interval=1 | YOLOv12x @ 1280px or ensemble |
| **Tracking** | NvDCF (frame-by-frame, causal) | ByteTrack or global optimization (forward + backward) |
| **Species ID** | Single class label from detector | VLM per-crop with species confidence |
| **Output** | Live Phoenix dashboard | Database + report |

## Pipeline Design

```
Video file (any format)
  --> Frame extraction (ffmpeg/OpenCV, configurable FPS)
  --> Detection (heavy YOLO or ensemble, every frame, batch GPU)
  --> Tracking (offline global tracker, bidirectional)
  --> Per-track thumbnail cropping
  --> Species classification (VLM with image context)
  --> Results to database
```

### Stage 1: Frame Extraction

Extract frames at a configurable rate. For maximum accuracy, extract every frame.
For efficiency on long videos, 2-5 FPS may suffice since fish don't move far between frames.

### Stage 2: Detection

Run the same YOLOv12x model (or a larger variant) without real-time constraints:

- Higher input resolution (1280px instead of 640px) for small fish
- Lower confidence threshold (0.10) to catch marginal detections
- Optionally run multiple models and merge detections (ensemble NMS)
- Batch processing: load N frames into GPU memory at once

Can reuse the existing ONNX model (`cfd-yolov12x-1.00.onnx`) via ultralytics or TensorRT directly.

### Stage 3: Tracking

Unlike real-time (causal, frame-by-frame), offline tracking can:

- **Forward + backward pass**: Run tracker in both directions, merge trajectories
- **Global optimization**: Hungarian algorithm over full detection sequence
- **Interpolation**: Fill gaps where detection was missed but fish was clearly present
- Libraries: ByteTrack, BoT-SORT, or custom global assignment

This eliminates the ID switches that plague real-time tracking.

### Stage 4: Species Classification via VLM

For each unique track, extract the best crop (highest confidence detection) and send to a VLM:

```
Prompt: "Identify the fish species in this image.
         Environment: underwater reef camera, [location].
         Respond with: species name, confidence (high/medium/low),
         and brief reasoning."
```

Options:
- **Claude API** (claude-sonnet-4-5-20250514 or claude-opus-4-20250514): Best accuracy, cost per image
- **Local VLM** (LLaVA, InternVL): Free, runs on GPU, lower accuracy
- **Hybrid**: Use local model for high-confidence classifications, escalate uncertain ones to Claude

Rate limiting: batch crops, send N per API call where supported.

### Stage 5: Results Storage

Store in a database (Postgres via Ecto in Phoenix app, or SQLite for standalone):

- Video metadata (file, duration, camera location, date)
- Per-track records (track_id, species, confidence, frame range, best crop)
- Aggregate counts per species per video
- Linkage to real-time session data if applicable

## Implementation Options

### Option A: Python Script (simplest)

Standalone script using ultralytics + Claude API. Processes a video, outputs JSON/CSV.
Good for: quick experiments, one-off analysis.

### Option B: Phoenix-integrated GenServer

An Elixir GenServer in the existing Phoenix app that:
- Accepts video processing jobs via the dashboard UI
- Shells out to Python/ONNX for detection
- Calls VLM API for species ID
- Stores results in Ecto
- Displays results alongside real-time data in the dashboard

Good for: unified UI, comparing real-time vs offline counts.

### Option C: Separate Docker Service

A GPU-enabled container that:
- Watches `/videos/inbox/` for new files
- Processes them through the full pipeline
- Writes results to a shared database
- Phoenix app reads and displays results

Good for: production deployment, decoupled from live system.

## NvMultiObjectTracker for Offline

The existing DeepStream NvDCF tracker CAN run on files (not just RTSP):

```
SOURCE_URIS="file:///videos/cam_1.mp4" FILE_LOOP=0
```

With `live-source=FALSE` on the streammux, it processes at full GPU speed.
However, this is still a causal (forward-only) tracker and doesn't support
the bidirectional / global optimization that makes offline tracking superior.

Best use: quick offline pass with existing infrastructure.
For maximum accuracy: use a dedicated offline tracker (ByteTrack/BoT-SORT).

## Recommended Starting Point

Start with **Option A** (Python script) to validate the approach:

1. Use ultralytics YOLOv12 for detection (same model weights)
2. Use ByteTrack for offline tracking
3. Use Claude API for species classification on best crops
4. Output to JSON, review results manually
5. Once validated, integrate into Phoenix (Option B) for dashboard access

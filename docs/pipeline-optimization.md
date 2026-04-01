# DeepStream Pipeline — Optimization Guide

Current setup: CFD YOLOv12x (FP16, 640x640) + NvDCF tracker on GTX 1080 Ti,
DeepStream 6.4, 1–3 RTSP sources via custom C++ pipeline.

## Detection

### Pre-cluster threshold

`config_infer_primary_cfd_yolov12_ds64.txt` — `pre-cluster-threshold`

Controls the minimum confidence before NMS runs. Higher values reduce noise but
filter out valid detections. Underwater fish often score low due to blur,
turbidity, and refraction.

| Value | Behaviour |
|-------|-----------|
| 0.25  | Conservative — misses many fish |
| 0.15  | Balanced — lets NMS handle duplicates |
| 0.10  | Aggressive — more detections, more tracker load |

Start at 0.15 and lower only if fish are still missed.

### Inference interval

`config_infer_primary_cfd_yolov12_ds64.txt` — `interval`
`config.cpp` — `INFER_INTERVAL` env var

`interval=N` means inference runs every N+1 frames. The tracker interpolates
bounding boxes on skipped frames.

| interval | Frames between inference | Latency at 30fps | GPU cost |
|----------|------------------------|-------------------|----------|
| 0        | Every frame             | 33ms              | Highest  |
| 1        | Every 2nd frame         | 66ms              | ~50%     |
| 2        | Every 3rd frame         | 100ms             | ~33%     |
| 3        | Every 4th frame         | 133ms             | ~25%     |

For fast-moving fish, interval=1 or lower is recommended. interval=3 creates
too large a gap — fish can transit the frame between inference frames, and
tentative tracks get terminated before the next detection can confirm them.

### Input resolution

`config_infer_primary_cfd_yolov12_ds64.txt` — `infer-dims`

Currently 640x640. Lowering to 480x480 gives a significant speedup (~40%) and
frees GPU headroom to run interval=0. Trade-off: smaller fish may be missed.
Requires rebuilding the TensorRT engine (delete the `.engine` file).

### INT8 quantization

~2x speedup over FP16 on the 1080 Ti. Requires a calibration dataset
(representative frames from the target environment). See
`DeepStream-Yolo/docs/INT8Calibration.md` for the calibration workflow.
Accuracy loss is typically small for detection tasks.

### Model size

YOLOv12x is the largest variant. If detection accuracy at threshold=0.15 is
sufficient, stepping down to YOLOv12l or YOLOv12m frees significant GPU budget
and may allow interval=0 with room to spare.

## Tracker (NvDCF)

### Tracker resolution

`config.cpp` — `TRACKER_WIDTH` / `TRACKER_HEIGHT` (default 640x384)

NvDCF correlation runs on every frame regardless of inference interval. This is
a per-frame GPU cost. Lowering to 480x288 reduces tracker overhead. Must be
multiples of 32.

### Feature extraction

`config_tracker_NvDCF_fish.yml` — VisualTracker section

- **`useColorNames: 0`** — color features are unreliable underwater (lighting
  shifts, green/blue cast). Disabling saves GPU compute per frame.
- **`useHog: 0`** — already disabled; correct for underwater.
- **`featureImgSizeLevel`** — lower values (1–2) are cheaper. Level 3 is only
  needed if the inference interval is high and the tracker must carry tracks
  longer between detections.

### State estimator

`stateEstimatorType: 1` (SIMPLE) vs `2` (REGULAR)

The REGULAR estimator uses a more complex Kalman model. Fish motion is erratic
enough that the simpler model may perform equally well at lower per-track cost.
Worth testing — switch to 1 and compare track continuity.

### Max targets

`maxTargetsPerStream: 150` — if typical scenes have <30 fish, lowering this
reduces memory allocation and association matrix size.

## Pipeline architecture

### Muxer batch timeout

`config.h` — `muxer_batch_timeout` (default 1000µs = 1ms)

With multiple sources, a 1ms timeout pushes incomplete batches (only the first
source's frame). Set to ~33000µs (one frame period at 30fps) to collect all
sources before pushing a full batch to inference.

Single-source setups are unaffected.

### OSD (on-screen display)

`nvdsosd` runs on GPU by default. Bounding box and text rendering is cheap
enough for CPU. Moving to software OSD frees GPU cycles for inference and
tracking. Set `process-mode=2` for CPU rendering.

### H.264 encoding

`nvv4l2h264enc` uses the GPU's NVENC hardware encoder. On the 1080 Ti, NVENC
has limited sessions. With many output streams, encoding can bottleneck.
Options:
- Lower `rtsp_bitrate` (currently 4Mbps)
- Increase `iframeinterval` (currently 15) to reduce encoder load
- Use software encoding for non-critical output streams

### Thumbnail extraction

When enabled, `NvBufSurfTransform` runs in the tracker probe callback, blocking
the pipeline thread. For high-throughput scenarios, move crop extraction to a
separate thread with a ring buffer to decouple it from the pipeline.

## Quick reference

| Change | Impact | Effort |
|--------|--------|--------|
| Lower pre-cluster-threshold to 0.15 | High | Config edit |
| Reduce interval to 1 | High | Config edit |
| Disable useColorNames | Medium | Config edit |
| Lower tracker resolution to 480x288 | Medium | Config edit |
| Reduce input resolution to 480x480 | High | Engine rebuild |
| INT8 quantization | High | Calibration dataset |
| Smaller model (YOLOv12l/m) | High | Engine rebuild |
| OSD to CPU (process-mode=2) | Low | Config edit |
| Increase muxer batch timeout | Low | Code edit |

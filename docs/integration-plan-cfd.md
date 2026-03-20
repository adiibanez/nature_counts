# Integration Plan: Community Fish Detector into NatureCounts

## Goal

Replace or supplement the current YOLO-Fish (darknet YOLOv3) model with the
Community Fish Detector (CFD) YOLOv12x model, which was trained on a much
larger and more diverse dataset (17 sources, 1.9M images, 935K bounding boxes
vs. 2 sources for YOLO-Fish).

## Chosen Approach: DeepStream 6.0.1 with ONNX via DeepStream-Yolo

After evaluating three paths (standalone ultralytics, ONNX in DeepStream, direct
TensorRT export), **Path B (ONNX in DeepStream)** was selected using the
[DeepStream-Yolo](https://github.com/marcoslucianops/DeepStream-Yolo) project's
export scripts and custom bbox parser. This keeps us on DS 6.0.1 (compatible
with the GTX 1080 Ti / driver 470 / CUDA 11.4 setup) while gaining YOLOv12
support.

### Why not the other paths?

- **Path A (standalone ultralytics):** No hardware-accelerated multi-stream
  muxing/decode. Not viable for 6 simultaneous RTSP streams.
- **Path C (direct TensorRT export):** Requires building the engine on the
  target GPU. Less portable and harder to debug than ONNX → TensorRT auto-build.

## Hardware Constraints

- **GPU:** GTX 1080 Ti (11 GB VRAM, Pascal architecture)
- **Driver:** 470, CUDA 11.4, TensorRT 8.0 (via DS 6.0.1 container)
- **Throughput:** YOLOv12x at 640px ≈ 12-15 FPS total inference
- **Strategy:** `interval=3` (infer every 4th frame) + NvDCF tracker fills gaps

## Step-by-Step Setup

### Prerequisites

1. Download CFD weights:
   ```bash
   wget -O deepstream-app-fish/cfd-yolov12x-1.00.pt \
     https://github.com/filippovarini/community-fish-detector/releases/download/cfd-1.00-yolov12x/cfd-yolov12x-1.00.pt
   ```

2. Update DeepStream-Yolo to get YOLOv12 export support:
   ```bash
   cd DeepStream-Yolo && git pull origin master
   ```
   Verify `utils/export_yoloV12.py` exists after update.

### Step 1: Export .pt → ONNX

Requires a Python environment with `ultralytics` + `torch` (not available
inside the DS container). Use host conda env or ultralytics Docker.

```bash
pip install ultralytics onnxsim onnx

python3 DeepStream-Yolo/utils/export_yoloV12.py \
  -w deepstream-app-fish/cfd-yolov12x-1.00.pt \
  --opset 12 \
  --simplify \
  -s 640
```

Key decisions:
- `--opset 12`: Required for TensorRT 8.0 in DS 6.0.1
- `--simplify`: Folds YOLOv12 Area Attention ops for TRT 8.0 compatibility
- `-s 640`: Starting at 640px for performance. Can re-export at 1024px if
  detection quality is insufficient (the CFD was trained at 1024px).

Copy outputs:
```bash
cp cfd-yolov12x-1.00.onnx deepstream-app-fish/
cp labels.txt deepstream-app-fish/cfd_labels.txt
```

### Step 2: Build custom parser library

The parser `.so` must be compiled inside the DS container (links against
container TensorRT/CUDA headers).

```bash
./build-deepstream-yolo.sh
```

This builds the updated DeepStream-Yolo parser and copies it to
`deepstream-app-fish/libnvdsinfer_custom_impl_Yolo_cfd.so`. The old YOLOv3
parser (`nvdsinfer_custom_impl_Yolo/libnvdsinfer_custom_impl_Yolo.so`) is
untouched.

### Step 3: Test with single video

```bash
# Place a test video in videos/test.mp4, then:
xhost +local:docker
./run-docker-deepstream-cfd.sh
# Inside container, override the config:
# deepstream-app -c .../test_cfd_singlevideo.txt
```

Or run the single-video test directly:
```bash
docker run --gpus all -it --rm -v /tmp/.X11-unix:/tmp/.X11-unix \
  -w /opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app-fish/ \
  -v $(pwd)/videos:/videos \
  -v $(pwd)/deepstream-app-fish/:/opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app-fish \
  -e DISPLAY=$DISPLAY nvcr.io/nvidia/deepstream:6.0.1-samples deepstream-app \
  -c /opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app-fish/test_cfd_singlevideo.txt
```

First run builds the TensorRT engine (~5-15 min). Subsequent runs reuse the
cached `.engine` file.

### Step 4: Run 6-stream live

**Display mode:**
```bash
xhost +local:docker
./run-docker-deepstream-cfd.sh
```

**Headless mode (production):**
```bash
./run-docker-deepstream-cfd-headless.sh
```

## Files Created

| File | Purpose |
|------|---------|
| `build-deepstream-yolo.sh` | Compiles DeepStream-Yolo parser inside DS container |
| `deepstream-app-fish/config_infer_primary_cfd_yolov12.txt` | nvinfer config for CFD YOLOv12x |
| `deepstream-app-fish/cfd_labels.txt` | Single class: "fish" |
| `deepstream-app-fish/test_tracker_cfd.txt` | 6-stream app config, display mode (EglSink + NvDCF) |
| `deepstream-app-fish/test_tracker_cfd_headless.txt` | 6-stream app config, headless (FakeSink + IOU) |
| `deepstream-app-fish/test_cfd_singlevideo.txt` | Single-video test config (batch=1, interval=0) |
| `run-docker-deepstream-cfd.sh` | Docker launch script, display mode |
| `run-docker-deepstream-cfd-headless.sh` | Docker launch script, headless |

## Files Untouched (YOLOv3 fallback preserved)

- `deepstream-app-fish/config_infer_primary_yoloV3.txt`
- `deepstream-app-fish/yolov3.cfg`, `yolov3.weights`
- `deepstream-app-fish/nvdsinfer_custom_impl_Yolo/libnvdsinfer_custom_impl_Yolo.so`
- `deepstream-app-fish/test_tracker_yolofish.txt`, `test_tracker_yolofish_headless.txt`
- `run-docker-deepstream.sh`, `run-docker-deepstream-headless.sh`

## Verification Checklist

1. **Single video:** Run `test_cfd_singlevideo.txt` with a known fish video.
   Confirm bounding boxes appear on fish.
2. **6-stream live:** Run `test_tracker_cfd.txt`. Check perf output — target
   ≥8 FPS per stream with `interval=3`.
3. **A/B comparison:** Run same video through YOLOv3 (`test_tracker_yolofish.txt`)
   and CFD (`test_tracker_cfd.txt`), compare detection quality.
4. **Tune interval:** If FPS too low → increase interval. If FPS comfortable →
   decrease interval or re-export at 1024px.

## Known Risks

1. **TensorRT 8.0 + YOLOv12 attention ops:** YOLOv12's Area Attention may
   produce ONNX ops unsupported by TRT 8.0. Mitigation: `--simplify` +
   `--opset 12` during export. If it still fails, may need DS 6.2+
   (requires driver 525+).
2. **VRAM:** YOLOv12x + 6 decoded streams + tracker ≈ 7-8 GB of 11 GB.
   Should fit, but monitor with `nvidia-smi`.
3. **640px vs 1024px accuracy:** Starting at 640px for performance. The much
   larger training set (17 datasets vs 2) should compensate, but may need
   1024px for small/distant fish.

## Performance Tuning Notes

- `interval=3` in `[primary-gie]` means inference runs on every 4th frame
  (frames 0, 4, 8, ...). The tracker interpolates positions on skipped frames.
- NvDCF (accuracy preset) is used in display mode for better visual tracking.
  IOU tracker is used in headless mode for lower GPU overhead.
- If VRAM is tight, try `network-mode=2` (FP16) in the nvinfer config —
  Pascal supports FP16 (slower than Volta+ but still faster than FP32 for
  larger models).

# DeepStream Pipeline — Current Setup

## Architecture Overview

The project uses NVIDIA DeepStream 6.0.1 running inside Docker to perform
real-time fish detection on RTSP camera streams, with object tracking and
optional RTSP re-streaming / YouTube forwarding.

```
RTSP cameras (6x)
    │
    ▼
┌──────────────────────────────────────────┐
│  Docker: nvcr.io/nvidia/deepstream:6.0.1 │
│                                           │
│  source0 (MultiURI, 6 RTSP streams)      │
│      │                                    │
│      ▼                                    │
│  streammux (1920x1080, batch=6)           │
│      │                                    │
│      ▼                                    │
│  primary-gie (YOLOv3 via custom parser)   │
│      │                                    │
│      ▼                                    │
│  tracker (NvDCF accuracy or IOU)          │
│      │                                    │
│      ▼                                    │
│  OSD (bboxes + text)                      │
│      │                                    │
│      ▼                                    │
│  tiled-display (2x3, 1920x1080)           │
│      │                                    │
│      ├──▶ sink0: EglSink (display) or     │
│      │         FakeSink (headless)         │
│      ├──▶ sink3: RTSP out (:8554)         │
│      └──▶ sink1: File (disabled)          │
└──────────────────────────────────────────┘
    │
    ▼ (optional)
ffmpeg → YouTube RTMP live stream
```

## Docker Launch Scripts

### With display (`run-docker-deepstream.sh`)

```bash
docker run --gpus all -it --rm \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -p 8555:8554 \
  -w /opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app-fish/ \
  -v $(pwd)/videos:/videos \
  -v /home/adrianibanez/projects/2022_naturecounts/deepstream-app-fish/:/opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app-fish \
  -e DISPLAY=$DISPLAY \
  nvcr.io/nvidia/deepstream:6.0.1-samples \
  deepstream-app -c .../test_tracker_yolofish.txt
```

### Headless (`run-docker-deepstream-headless.sh`)

Same but without X11 forwarding and uses `test_tracker_yolofish_headless.txt`
(sink0 type=1 FakeSink instead of type=2 EglSink).

### Known Issues / Why It Doesn't Work

1. **DeepStream 6.0.1 is very old** (Dec 2021). The Docker image
   `nvcr.io/nvidia/deepstream:6.0.1-samples` may no longer be available or
   compatible with current NVIDIA drivers. Check `nvidia-smi` driver version
   vs. the CUDA version baked into the container.

2. **Hardcoded RTSP source** — `rtsp://192.168.1.195:8554/cam%d` assumes a
   specific camera server on the local network. If that server is down or the
   IP has changed, DeepStream will fail at source negotiation.

3. **Custom YOLO parser library** — The config references
   `nvdsinfer_custom_impl_Yolo/libnvdsinfer_custom_impl_Yolo.so` which must
   be compiled inside the container against the correct DeepStream/TensorRT
   version. A precompiled `.so` exists in `deepstream-app-fish/` but may be
   stale.

4. **Model engine cache** — `model_b1_gpu0_fp32.engine` is GPU-specific. If
   the GPU has changed, the engine must be rebuilt (delete the file and let
   nvinfer regenerate it from `yolov3.cfg` + `yolov3.weights`).

5. **Port mapping** — The script maps host 8555 → container 8554, so the
   RTSP output is at `rtsp://localhost:8555/ds-test`.

6. **X11 forwarding** — The display variant requires `xhost +local:docker`
   on the host before running.

## Config Files (deepstream-app-fish/)

| File | Purpose |
|------|---------|
| `test_tracker_yolofish.txt` | Main app config — display mode, 6 RTSP sources, YOLOv3, NvDCF tracker |
| `test_tracker_yolofish_headless.txt` | Same but FakeSink + IOU tracker |
| `config_infer_primary_yoloV3.txt` | nvinfer config for YOLOv3 (custom parser, 1 class) |
| `config_infer_primary_endv.txt` | nvinfer config for Endeavour Caffe model (1 class) |
| `config_infer_primary.txt` | nvinfer config for ResNet10 (4 classes, INT8) |
| `config_infer_primary_nano.txt` | nvinfer config for ResNet10 Nano (FP16, batch 8) |
| `yolov3.cfg` | Darknet YOLOv3 network definition |
| `yolov3.weights` | Darknet YOLOv3 trained weights (YOLO-Fish) |
| `yolo3_labels.txt` | Single label: "Fish" |
| `config_tracker_NvDCF_accuracy.yml` | NvDCF tracker (accuracy preset) |
| `config_tracker_IOU.yml` | Simple IOU tracker |
| `libnvdsinfer_custom_impl_Yolo.so` | Compiled custom bbox parser for YOLO |

## Camera Setup

- 6 RTSP streams from `rtsp://192.168.1.195:8554/cam0..cam5`
- Smart recording enabled: 30s cache, saves to `/videos/smart-rec/`
- RTSP reconnect: every 5s, max 10 attempts

## YouTube Streaming (ffmpeg)

The `ffmpeg-youtube-command.txt` shows how to forward the RTSP output from
DeepStream to YouTube Live via RTMP, with an audio overlay.

## Debugging Steps

To troubleshoot the pipeline:

```bash
# 1. Check NVIDIA driver compatibility
nvidia-smi

# 2. Verify the Docker image is pullable
docker pull nvcr.io/nvidia/deepstream:6.0.1-samples

# 3. Test with a simple file source first (edit source0 to type=2, uri=file:///videos/somefile.mp4)

# 4. Check if custom lib compiles inside the container
docker run --gpus all -it --rm nvcr.io/nvidia/deepstream:6.0.1-samples bash
cd /opt/nvidia/deepstream/deepstream-6.0/sources/objectDetector_Yolo
make -C nvdsinfer_custom_impl_Yolo

# 5. Delete stale engine files to force regeneration
rm deepstream-app-fish/model_b*_gpu*_fp32.engine
```

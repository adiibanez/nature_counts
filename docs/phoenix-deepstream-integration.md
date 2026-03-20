# DeepStream + Phoenix Realtime Integration

## Architecture

```
IP Cameras / File (via FFmpeg)
         │
    MediaMTX :8554/raw-camN  (RTSP hub)
         │
    DeepStream Python (GPU)
    ├─ uridecodebin → videoconvert → nvvideoconvert → nvstreammux
    ├─ nvinfer (YOLOv12x, cfd-yolov12x-1.00 model)
    ├─ nvtracker (IOU)
    ├─ nvdsosd (bboxes baked into video frames)
    ├─ nvv4l2h264enc → rtph264pay → udpsink :5400
    ├─ GstRtspServer :8554/ds (RTSP output)
    └─ Probe → Phoenix Channel (detection metadata at 10 Hz)
         │                          │
    MediaMTX :8554/cam1         Phoenix :4005
    (pulls processed RTSP)      (Elixir/LiveView)
         │                          │
    WebRTC :8889               Dashboard + Stats
         │                     (Active tracks, fish counts)
    Browser <video>
    (bboxes in video, ~200ms latency)
```

## Services (docker-compose)

| Service | Image | Ports | Purpose |
|---------|-------|-------|---------|
| **mediamtx** | Custom (bluenviron/mediamtx + ffmpeg) | 8554, 8888, 8889, 8189 | RTSP hub, WebRTC/HLS output |
| **deepstream** | nvcr.io/nvidia/deepstream:6.0.1-samples + Python | 8554 (internal) | GPU inference pipeline |
| **phoenix** | Elixir 1.18 release | 4005 | Web UI, realtime stats |

## Key Design Decisions

### Frame-perfect bbox sync
Bounding boxes are rendered by `nvdsosd` directly on GPU frames before H264 encoding. Zero sync offset — the video stream IS the visualization.

### WebRTC for low latency
MediaMTX converts the RTSP output to WebRTC (~200ms latency) via its built-in WHEP endpoint. The browser connects to `http://localhost:8889/cam1/whep`.

### Two-socket Phoenix architecture
- **DeepstreamSocket** (`/deepstream/websocket`) — Python pipeline pushes detection metadata (token auth)
- **UserSocket** (`/user/websocket`) — browsers receive stats via DetectionChannel

### RTSP-first source model
All video sources enter as RTSP — even local files are streamed through MediaMTX via FFmpeg. This means the DeepStream pipeline code is identical for testing (files) and production (IP cameras).

## File Structure

```
deepstream-python/
  ds_fish_pipeline.py          # Main pipeline: source → infer → track → OSD → RTSP + Phoenix
  phoenix_channel_client.py    # Phoenix v2 wire protocol WebSocket client
  Dockerfile                   # DS 6.0.1 + pyds 1.1.1 + websockets
  requirements.txt             # websockets>=8.0,<10.0

phoenix-app/
  lib/naturecounts/
    detection/
      detection_event.ex       # DetectionEvent, DetectedObject, BBox structs
      tracker_state.ex         # ETS-backed GenServer: per-cam track history + fish counting
  lib/naturecounts_web/
    channels/
      deepstream_socket.ex     # Token-auth socket for Python pipeline
      user_socket.ex           # Browser client socket
      ingestion_channel.ex     # Receives detection_batch → PubSub broadcast
      detection_channel.ex     # Pushes detection_update to browsers
    live/
      dashboard_live.ex        # Multi-camera grid with stats
      camera_live.ex           # Single camera view with detailed stats
  assets/js/hooks/
    video_overlay.js           # WebRTC player (WHEP) + stats channel

mediamtx.yml                   # MediaMTX config: raw-camN inputs, camN outputs
Dockerfile.mediamtx            # MediaMTX + ffmpeg for file playback
docker-compose.yml             # 3 services, no Redis
```

## Configuration

### Environment Variables (deepstream)

| Variable | Default | Description |
|----------|---------|-------------|
| `SOURCE_URIS` | — | Comma-separated RTSP URIs (e.g. `rtsp://mediamtx:8554/raw-cam1`) |
| `RTSP_BASE_URI` | `rtsp://mediamtx:8554/raw-cam` | Base URI; appends 1,2,3... |
| `NUM_SOURCES` | 1 | Number of sources when using RTSP_BASE_URI |
| `RTSP_OUT_PORT` | 8554 | GstRtspServer listen port |
| `RTSP_BITRATE` | 4000000 | H264 output bitrate |
| `PHOENIX_URL` | `ws://phoenix:4005/deepstream/websocket` | Phoenix WebSocket URL |
| `DEEPSTREAM_TOKEN` | `dev-secret-token` | Shared secret for Phoenix auth |

### Environment Variables (phoenix)

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | 4005 | HTTP listen port |
| `NUM_CAMERAS` | 1 | Number of camera cards in dashboard |
| `DEEPSTREAM_TOKEN` | `dev-secret-token` | Must match deepstream's token |
| `SECRET_KEY_BASE` | — | Phoenix cookie signing (≥64 bytes) |

### Adding Real IP Cameras

Edit `mediamtx.yml`:

```yaml
paths:
  raw-cam1:
    source: rtsp://192.168.1.195:8554/cam1
  raw-cam2:
    source: rtsp://192.168.1.195:8554/cam2
```

Then set `SOURCE_URIS=rtsp://mediamtx:8554/raw-cam1,rtsp://mediamtx:8554/raw-cam2` and `NUM_CAMERAS=2`.

### SSH Remote Access

Forward these ports:

```bash
ssh -L 4005:localhost:4005 -L 8889:localhost:8889 user@server
```

Port 8189 (WebRTC ICE/UDP) doesn't tunnel over SSH. For TCP-only access, configure MediaMTX for TCP-only WebRTC or fall back to HLS on port 8888.

## Existing DeepStream Configs Reused

- `deepstream-app-fish/config_infer_primary_cfd_yolov12.txt` — nvinfer config (YOLOv12x, 640×640, FP32)
- `deepstream-app-fish/config_tracker_IOU.yml` — IOU tracker (probation=4, max_shadow=38)
- `deepstream-app-fish/cfd-yolov12x-1.00.onnx_b1_gpu0_fp32.engine` — cached TensorRT engine
- `deepstream-app-fish/libnvdsinfer_custom_impl_Yolo_cfd.so` — custom YOLO bbox parser
- `deepstream-app-fish/cfd_labels.txt` — single class: "fish"

## Running

```bash
docker compose up --build
```

Open `http://localhost:4005` for the Phoenix dashboard.

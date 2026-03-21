# NatureCounts — Fish Detection Pipeline

Real-time fish detection and tracking using DeepStream 6.4, YOLOv12, and a Phoenix LiveView dashboard.

## Architecture

```
video files ──► mediamtx (RTSP hub) ──► DeepStream (GPU inference + tracking)
                                              │
                                              ├─► rtspclientsink ──► mediamtx ──► WebRTC ──► browser
                                              └─► pyds metadata ──► Phoenix channels ──► browser fish list
```

Three services (docker compose):

| Service | Port | Role |
|---------|------|------|
| **mediamtx** | 8554 (RTSP), 8889 (WebRTC) | RTSP hub, loops simulator videos, serves WebRTC to browsers |
| **deepstream** | — | YOLOv12 inference, IOU tracker, per-camera H264 encoding, detection extraction |
| **phoenix** | 4005 | LiveView dashboard, receives detections via WebSocket, broadcasts to browsers |

## Quick Start

```bash
# 1. Prepare simulator videos (one-time)
./videos/preencode.sh

# 2. Start everything
docker compose up -d

# 3. Open browser
#    Dashboard:  http://localhost:4005
#    Direct cam: http://localhost:8889/cam1/
```

## Simulator Videos

The pipeline uses pre-recorded video files as simulated camera feeds. MediaMTX loops them via ffmpeg as RTSP streams that DeepStream consumes.

### Preparing video files

Videos must be H.264 encoded with clean keyframes for RTSP streaming. The `preencode.sh` script handles this:

```bash
cd videos/

# Encode the default files (referenced by mediamtx.yml)
./preencode.sh

# Or encode specific files
./preencode.sh my_video.mp4 another.mp4
```

This creates RTSP-ready copies in `videos/rtsp-ready/`. Files already in H.264 are remuxed (no re-encode); other codecs are transcoded to H.264.

**Requirements for source videos:**
- Any format ffmpeg can read (MP4, AVI, MKV, etc.)
- Any resolution (DeepStream scales to 1920x1080 via streammux)
- Audio is stripped automatically

### Configuring which videos play on which camera

Edit `mediamtx.yml` — each `raw-camN` path loops one video file:

```yaml
paths:
  raw-cam1:
    runOnInit: >
      ffmpeg -re -stream_loop -1
      -i /videos/rtsp-ready/YOUR_VIDEO.mp4
      -an -c:v copy
      -f rtsp rtsp://localhost:$RTSP_PORT/$MTX_PATH
    runOnInitRestart: yes
```

- `-re` plays at real-time speed (not as fast as possible)
- `-stream_loop -1` loops forever
- `-c:v copy` streams without re-encoding (requires pre-encoded H.264)
- The path name (`raw-cam1`) must match what DeepStream expects in `SOURCE_URIS`

### Adding or removing cameras

1. Add/remove `raw-camN` entries in `mediamtx.yml`
2. Add/remove corresponding `camN:` entries for processed output
3. Update `docker-compose.yml`:
   - `SOURCE_URIS` — comma-separated list of raw RTSP URIs
   - `NUM_CAMERAS` — number of cameras for Phoenix dashboard

### Using real cameras instead of files

Replace the `runOnInit` ffmpeg command with a `source` directive:

```yaml
paths:
  raw-cam1:
    source: rtsp://192.168.1.195:8554/stream
```

## Video Conversion Script

`videos/preencode.sh` converts any video to RTSP-ready H.264:

```
Usage: ./preencode.sh [file1.mp4 file2.mp4 ...]

  No arguments: processes default files (P5_2025-03-07_420.mp4, cam_1.mp4, cam_2.mp4)
  With arguments: processes the specified files

Output: videos/rtsp-ready/<filename>.mp4
```

**What it does:**
- H.264 files: remux with `faststart` flag (instant, no quality loss)
- Other codecs: transcode to H.264, CRF 18, medium preset, 50-frame GOP
- Strips audio
- Outputs to `videos/rtsp-ready/`

## Environment Variables

### DeepStream (`docker-compose.yml` → deepstream service)

| Variable | Default | Description |
|----------|---------|-------------|
| `SOURCE_URIS` | `rtsp://mediamtx:8554/raw-cam1,...` | Comma-separated input RTSP URIs |
| `RTSP_BITRATE` | `4000000` | H264 encoder bitrate (bps) |
| `RTSP_OUTPUT_BASE` | `rtsp://mediamtx:8554/cam` | Base URI for output streams (appends 1,2,3...) |
| `PHOENIX_URL` | `ws://phoenix:4005/deepstream/websocket` | Phoenix WebSocket endpoint |

### Phoenix (`docker-compose.yml` → phoenix service)

| Variable | Default | Description |
|----------|---------|-------------|
| `MEDIAMTX_HOST` | `localhost:8889` | MediaMTX WebRTC host (as seen by the browser) |
| `NUM_CAMERAS` | `3` | Number of camera tiles in dashboard |
| `CAMERAS` | `webrtc` | Set to `rtsp` for Membrane pipelines, `webrtc` for MediaMTX |

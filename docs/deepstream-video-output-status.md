# DeepStream Video Output — Work-in-Progress Status

**Date:** 2026-03-20
**Goal:** Get DeepStream processed video (with bounding boxes) to the browser via MediaMTX WebRTC.

## Current Architecture

```
Sources (RTSP from MediaMTX)
  → nvstreammux → nvinfer(YOLOv12) → nvtracker(IOU)
    → tee
      ├─ [probe] metadata → Phoenix WebSocket (WORKING)
      ├─ nvdsosd → nvmultistreamtiler → nvvideoconvert → nvv4l2h264enc
      │    → h264parse → rtph264pay → udpsink(localhost:5400)
      │    → ffmpeg reads local UDP, pushes RTSP/TCP to mediamtx
      └─ nvvideoconvert → appsink (thumbnail crops from tiled frame)

MediaMTX: receives RTSP push on `cam1` path → serves WebRTC/HLS to browser
```

## What Works

- **Detection pipeline:** Sources → mux → inference → tracker → probe → Phoenix. Fully working. Detections flow to browser at 10Hz.
- **Tiler-based rendering:** OSD draws bboxes on batched GPU frames, tiler composites all cameras into one 1920x1080 view, encoder produces H.264. Confirmed with flow probes (1000+ encoder buffers).
- **Thumbnails:** Adapted to crop from the tiled frame using computed tile offsets. Not yet verified end-to-end.

## What Doesn't Work (and why)

### 1. `rtspclientsink` (GStreamer 1.14.5 bug)
**Tried:** Replace `rtph264pay → udpsink` with `rtspclientsink` pushing directly to MediaMTX.
**Result:** Ghost pad in `rtspclientsink` has no target until CAPS arrive, but CAPS can't be delivered without a target. Chicken-and-egg deadlock in v1.14.5. The sink connects (OPTIONS 200 OK), sends RECORD, but blocks forever at "Waiting for caps on stream 0".
**Workaround tried:** Priming caps via `sink_pad.send_event(Gst.Event.new_caps(...))` — this creates the payloader, but the preroll condition never fires because actual data buffers don't reach the ghost pad.
**Verdict:** Fundamentally broken on GStreamer 1.14. Would work on 1.16+.

### 2. `nvstreamdemux` (DeepStream 6.0 bug)
**Tried:** Demux batched stream into per-camera branches for separate cam1/cam2/cam3 outputs.
**Result:** Data enters the demux sink pad (confirmed with probe), but NOTHING comes out of the src pads. Zero buffers. Even with queues after demux. Even with fakesink downstream.
**Verdict:** `nvstreamdemux` is broken in DS 6.0. No DeepStream Python samples use it. All official samples use `nvmultistreamtiler` instead.
**Impact:** Cannot produce separate per-camera output streams. Current workaround is a single tiled view.

### 3. UDP RTP + ffmpeg inside MediaMTX
**Tried:** DeepStream sends `rtph264pay → udpsink` to mediamtx:5400. MediaMTX runs ffmpeg via `runOnInit` to read the SDP and push to itself.
**Result:** Port bind conflicts. ffmpeg exits and restarts via `runOnInitRestart`, but the socket is still in TIME_WAIT, causing "bind failed: Address already in use". Also timing issues — ffmpeg starts before DeepStream sends data.

## Current Approach (in progress, not yet tested)

**ffmpeg forwarder inside DeepStream container:**
1. Pipeline sends `rtph264pay → udpsink` to `localhost:5400` (same container)
2. Python launches ffmpeg as subprocess: reads local UDP via SDP, pushes RTSP/TCP to `rtsp://mediamtx:8554/cam1`
3. MediaMTX auto-creates `cam1` path via `all_others` wildcard
4. No port conflicts (ffmpeg and udpsink in same container)
5. No timing issues (ffmpeg launched after pipeline starts)

**Files modified:**
- `deepstream-python/ds_fish_pipeline.py` — pipeline rewrite (tiler, ffmpeg forwarder)
- `deepstream-python/Dockerfile` — added `ffmpeg` package
- `mediamtx.yml` — removed cam1/cam2/cam3 ffmpeg blocks, kept `all_others` wildcard
- `docker-compose.yml` — removed `RTSP_OUT_PORT`, `expose`, `./config:/config`

**Files deleted:**
- `config/ds0.sdp`, `config/ds1.sdp`, `config/ds2.sdp`

## Key Constraints

- **DeepStream 6.0** ships GStreamer **1.14.5** (2019). Many modern GStreamer features are broken.
- **nvstreamdemux** is non-functional — per-camera output requires either upgrading DS or implementing custom frame extraction from batched buffers.
- **rtspclientsink** needs GStreamer 1.16+ to work with late-binding sources.
- The container is based on `nvcr.io/nvidia/deepstream:6.0.1-samples` (Ubuntu 18.04).

## Next Steps

1. **Verify ffmpeg forwarder** — check if `localhost:5400` UDP → ffmpeg → RTSP to mediamtx works
2. **Verify browser playback** — open `http://localhost:4005` and check cam1 video with bounding boxes
3. **Verify thumbnails** — check that detection events include base64 JPEG thumbnails
4. **Consider per-camera output** — if needed, options are:
   - Upgrade to DeepStream 6.1+ (has working `nvstreamdemux`)
   - Use `nvmultistreamtiler` with `show-source` property to switch views
   - Extract per-camera frames from batched buffer in a custom probe
5. **Remove debug code** — clean up flow probes, GST_DEBUG settings once stable

## File Locations

| File | Purpose |
|------|---------|
| `deepstream-python/ds_fish_pipeline.py` | Main pipeline + Phoenix integration |
| `deepstream-python/Dockerfile` | DeepStream container build |
| `deepstream-python/phoenix_channel_client.py` | WebSocket client for Phoenix |
| `mediamtx.yml` | MediaMTX config (RTSP/WebRTC/HLS) |
| `docker-compose.yml` | Service orchestration |
| `phoenix-app/` | Elixir/Phoenix web app |
| `videos/` | Test video files |
| `deepstream-app-fish/` | YOLO model configs + weights |

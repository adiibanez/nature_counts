# Upgrade DeepStream 6.0 → 6.4: Per-Camera Video Streams

## Why

The web UI expects separate video streams per camera (`cam1`, `cam2`, `cam3` via WebRTC).
DS 6.0 has broken `nvstreamdemux` and broken `rtspclientsink` (GStreamer 1.14 too old),
forcing a tiler + ffmpeg cropping workaround. Upgrading to DS 6.4 (GStreamer 1.20, CUDA 12.2)
fixes both and enables a clean per-camera architecture.

## Target Pipeline

```
sources → nvstreammux → nvinfer(YOLOv12) → nvtracker → nvstreamdemux
  ├─ src_0 → nvdsosd → encoder → rtspclientsink → mediamtx/cam1
  ├─ src_1 → nvdsosd → encoder → rtspclientsink → mediamtx/cam2
  └─ src_N → nvdsosd → encoder → rtspclientsink → mediamtx/camN
```

No tiler. No ffmpeg forwarder. Full resolution per camera.

## Files Created (Phase 2 — done)

| File | Purpose |
|------|---------|
| `Dockerfile.build-yolo-6.4` | Builder image for DS 6.4 parser (TRT 8.6 + CUDA 12.2) |
| `build-deepstream-yolo-6.4.sh` | Compiles YOLO parser → `libnvdsinfer_custom_impl_Yolo_cfd_ds64.so` |
| `deepstream-python/Dockerfile.ds64` | DS 6.4 Python container (Ubuntu 22.04, Python 3.10) |
| `deepstream-app-fish/config_infer_primary_cfd_yolov12_ds64.txt` | Inference config (no engine file — forces TRT rebuild) |
| `deepstream-python/ds_fish_pipeline.py` | Rewritten pipeline with nvstreamdemux per-camera branches |
| `docker-compose.ds64.yml` | Compose file for DS 6.4 stack |

## Rollback

- DS 6.0 files are untouched: `docker-compose.yml`, `Dockerfile`, `Dockerfile.build-yolo`, `build-deepstream-yolo.sh`
- DS 6.0 inference config: `config_infer_primary_cfd_yolov12.txt`
- DS 6.0 parser: `libnvdsinfer_custom_impl_Yolo_cfd.so`
- To roll back: `docker compose -f docker-compose.yml up` (driver 535 is backward-compatible with DS 6.0)

---

## Remaining Steps

### Phase 0: Snapshot Current State (before driver upgrade)

- [ ] Create initial git commit and tag: `git tag v1.0-ds6.0.1-working`
- [ ] Record driver state: `dpkg -l | grep nvidia > ~/backups/driver-inventory-470.txt`
- [ ] Tag Docker images: `docker tag <deepstream-image> deepstream-backup:6.0.1`
- [ ] Backup compiled artifacts to `~/backups/ds6.0.1/`:
  - `deepstream-app-fish/libnvdsinfer_custom_impl_Yolo_cfd.so`
  - `deepstream-app-fish/cfd-yolov12x-1.00.onnx_b3_gpu0_fp32.engine`
- [ ] Download driver 470 debs as safety net: `apt-get download nvidia-driver-470 nvidia-dkms-470 nvidia-utils-470`
- [ ] Confirm current pipeline works: run `docker compose up`, verify detections in browser

**Go/No-Go**: Tag exists, backups saved, current system confirmed working.

### Phase 1: Driver Upgrade (470 → 535-server)

- [ ] Stop all GPU workloads: `docker stop $(docker ps -q)`
- [ ] `sudo apt install nvidia-driver-535-server`
  - If DKMS fails → abort, still on 470
- [ ] `sudo reboot`
- [ ] Verify: `nvidia-smi` shows 535.x, CUDA 12.2
- [ ] Critical test: Run DS 6.0.1 pipeline on new driver — must still produce detections

**Rollback**: `sudo apt install nvidia-driver-470 && sudo reboot`

**Go/No-Go**: nvidia-smi works AND DS 6.0.1 pipeline still runs on driver 535.

### Phase 2: Build DS 6.4 Parser (done — code created)

- [ ] Run `./build-deepstream-yolo-6.4.sh`
  - Builds Docker builder image from `nvcr.io/nvidia/deepstream:6.4-samples`
  - Compiles with `CUDA_VER=12.2`
  - Outputs `deepstream-app-fish/libnvdsinfer_custom_impl_Yolo_cfd_ds64.so`

### Phase 3: Smoke Tests in DS 6.4 Container

- [ ] **Inference**: Run `deepstream-app` inside DS 6.4 container with YOLO model
  - First run rebuilds TensorRT engine from ONNX (several minutes)
- [ ] **nvstreamdemux**: Run `test_demux.py` inside DS 6.4 container
  - Must output buffers from demux src pads
  - If 0 buffers → DS 6.4 still broken, investigate DS 7.0
- [ ] **rtspclientsink**: `gst-inspect-1.0 rtspclientsink` inside DS 6.4 container
  - Must exist and show GStreamer 1.20
- [ ] **NVENC sessions**: Test 3 concurrent `nvv4l2h264enc` instances
  - GTX 1080 Ti has 2-3 session limit on consumer GPUs
  - If hit, apply nvidia-patch or fall back to software encoding

**Go/No-Go**: All three elements work. If any fails, stay on DS 6.0.1 (still working on driver 535).

### Phase 4: Deploy and Verify

- [ ] `docker compose -f docker-compose.ds64.yml up`
- [ ] Verify each camera at `http://localhost:8889/camN/whep`
- [ ] Verify bounding boxes visible on each stream
- [ ] Verify Phoenix Channel receives per-camera detections (browser console)
- [ ] Verify no ffmpeg subprocess running
- [ ] Tag: `git tag v2.0-ds6.4-working`

## Verification Checklist

1. `nvidia-smi` shows driver 535+
2. Each camera has its own WebRTC stream at `http://localhost:8889/camN/whep`
3. Web UI shows live video with bounding boxes on each camera page
4. Detection metadata flows to Phoenix (check browser console)
5. `docker compose logs deepstream` shows no ffmpeg, no tiler, demux pads linked

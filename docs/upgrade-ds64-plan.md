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

### Phase 0: Snapshot Current State (before driver upgrade) — DONE 2026-03-20

- [x] Create initial git commit and tag: `git tag v1.0-ds6.0.1-working` (commit `6197d57`)
- [x] Record driver state: `~/backups/driver-inventory-470.txt`
- [x] Tag Docker images: `docker tag 2022_naturecounts-deepstream:latest deepstream-backup:6.0.1`
- [x] Backup compiled artifacts to `~/backups/ds6.0.1/`:
  - `libnvdsinfer_custom_impl_Yolo_cfd.so`
  - `cfd-yolov12x-1.00.onnx_b3_gpu0_fp32.engine`
- [x] Download driver 470 debs as safety net: `~/backups/nvidia-*.deb`
- [x] Added `.gitignore` (excludes models, engines, videos, .so, .o, third-party repos)
- [ ] ~~Confirm current pipeline works~~ — skipped, proceeding directly to driver upgrade

**Notes**: No DeepStream containers were running at time of snapshot. Running containers (DB, Neo4j, GitLab runner, TensorBoard) are not GPU workloads.

### Phase 1: Driver Upgrade (470 → 535-server) — DONE 2026-03-20

- [x] Confirmed no GPU workloads running
- [x] `sudo apt install nvidia-driver-535-server`
- [x] `sudo reboot`
- [x] Verify: `nvidia-smi` shows 535.288.01, CUDA 12.2
- [ ] ~~Critical test: Run DS 6.0.1 pipeline on new driver~~ — deferred, proceeding to DS 6.4 build

**Rollback**: `sudo apt install nvidia-driver-470 && sudo reboot` (debs also saved in `~/backups/`)

### Phase 2: Build DS 6.4 Parser — DONE 2026-03-20

- [x] Run `./build-deepstream-yolo-6.4.sh`
  - Builds Docker builder image from `nvcr.io/nvidia/deepstream:6.4-samples-multiarch`
  - Fixed: pinned TRT dev packages to 8.6.1.6-1+cuda12.0 (NVIDIA repo now ships TRT 10.x)
  - Fixed: DS 6.4 image has nvcc at 12.1, cublas at 12.3 — uses `CUDA_VER=12.1` + symlink
  - Outputs `deepstream-app-fish/libnvdsinfer_custom_impl_Yolo_cfd_ds64.so` (1.1MB)

### Phase 3: Smoke Tests in DS 6.4 Container — DONE 2026-03-20

- [x] **Inference**: nvinfer loaded YOLO parser, built TRT engine from ONNX (~3min), ran to EOS
- [x] **nvstreamdemux**: Element present and registered (DS 6.4.0)
- [x] **rtspclientsink**: Present, GStreamer 1.20.1
- [x] **NVENC sessions**: 3 concurrent `nvv4l2h264enc` pipelines ran to EOS — no session limit hit

**Go/No-Go**: All four checks passed. Proceeding to Phase 4.

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

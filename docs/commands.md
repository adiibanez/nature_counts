# Commands - CFD YOLOv12x DeepStream Pipeline

## Prerequisites

1. **NVIDIA driver + Docker GPU runtime**
   ```bash
   nvidia-smi                    # verify driver is loaded
   docker run --gpus all --rm nvidia/cuda:11.4.3-base-ubuntu20.04 nvidia-smi  # verify GPU in Docker
   ```

2. **Pull the DeepStream image** (only needed once)
   ```bash
   docker pull nvcr.io/nvidia/deepstream:6.0.1-samples
   ```

3. **Required files in `deepstream-app-fish/`**
   - `cfd-yolov12x-1.00.onnx` - ONNX model (exported from CFD YOLOv12x)
   - `cfd_labels.txt` - label file (single class)
   - `libnvdsinfer_custom_impl_Yolo_cfd.so` - custom bbox parser (compiled for DS 6.0)
   - `config_infer_primary_cfd_yolov12.txt` - nvinfer config
   - `config_tracker_IOU.yml` - IOU tracker config
   - `test_cfd_singlevideo.txt` - app config (display mode)
   - `test_cfd_singlevideo_headless.txt` - app config (headless mode)

4. **Test video**
   - Place a video file in `videos/`, e.g. `BOCCocoPt_1_1652437801.mp4`
   - Update `uri=` in the app config if using a different file

## Running - Display Mode (EglSink)

Requires X11 forwarding. Run on the host first:
```bash
xhost +local:docker
```

Then launch:
```bash
./run-docker-new.sh
```

Or manually:
```bash
docker run --gpus all -it --rm \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    -e DISPLAY=$DISPLAY \
    -w /opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app-fish/ \
    -v /home/adrianibanez/projects/2022_naturecounts/videos:/videos \
    -v /home/adrianibanez/projects/2022_naturecounts/deepstream-app-fish/:/opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app-fish \
    nvcr.io/nvidia/deepstream:6.0.1-samples deepstream-app \
    -c /opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app-fish/test_cfd_singlevideo.txt
```

## Running - Headless Mode (FakeSink)

No display needed. Useful for benchmarking or remote/SSH sessions.

```bash
./run-docker-new_headless.sh
```

Or manually:
```bash
docker run --gpus all -it --rm \
    -w /opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app-fish/ \
    -v /home/adrianibanez/projects/2022_naturecounts/videos:/videos \
    -v /home/adrianibanez/projects/2022_naturecounts/deepstream-app-fish/:/opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app-fish \
    nvcr.io/nvidia/deepstream:6.0.1-samples deepstream-app \
    -c /opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app-fish/test_cfd_singlevideo_headless.txt
```

## Troubleshooting

### "Failed to parse config file"
- Config files must be pure ASCII. No UTF-8 characters (e.g. em dashes) in comments.
- Check that volume mounts are correct - use absolute paths or `cd` to the project directory first if using `$(pwd)`.

### "Failed to set pipeline to PAUSED"
- Display mode: make sure `xhost +local:docker` was run and `DISPLAY` is set.
- Headless mode: make sure sink type is `1` (FakeSink), not `2` (EglSink).

### Engine file regeneration
The first run builds a TensorRT engine from the ONNX model. This takes several minutes and is GPU-specific. If you change GPU, delete stale engines:
```bash
rm deepstream-app-fish/model_b*_gpu*_fp32.engine
```

### Batch-size mismatch
The inference config (`config_infer_primary_cfd_yolov12.txt`) batch-size must match or exceed the app config (`test_cfd_singlevideo*.txt`) batch-size. For single-video test, both should be `1`.

### GStreamer plugin warnings
These are harmless and can be ignored:
```
Failed to load plugin libnvdsgst_inferserver.so: libtritonserver.so: cannot open shared object file
Failed to load plugin libnvdsgst_udp.so: librivermax.so.0: cannot open shared object file
```

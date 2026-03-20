#!/bin/bash
# Build the DeepStream-Yolo custom parser library using a cached Docker image.
# The Dockerfile caches apt/TensorRT dev headers so only the make step runs
# on subsequent builds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="ds601-yolo-builder"

# Step 1: Build (or reuse cached) builder image with TensorRT dev headers
echo "=== Building builder image (cached after first run) ==="
docker build -t "${IMAGE_NAME}" -f "${SCRIPT_DIR}/Dockerfile.build-yolo" "${SCRIPT_DIR}"

# Step 2: Compile the parser .so (only this step reruns on code changes)
echo "=== Compiling DeepStream-Yolo parser ==="
docker run --gpus all --rm \
  -v "${SCRIPT_DIR}/DeepStream-Yolo:/DeepStream-Yolo" \
  -w /DeepStream-Yolo \
  "${IMAGE_NAME}" \
  bash -c "CUDA_VER=11.4 make -C nvdsinfer_custom_impl_Yolo clean && CUDA_VER=11.4 make -C nvdsinfer_custom_impl_Yolo"

echo "=== Build complete ==="

# Step 3: Copy with _cfd suffix to preserve the old .so for YOLOv3 fallback
cp "${SCRIPT_DIR}/DeepStream-Yolo/nvdsinfer_custom_impl_Yolo/libnvdsinfer_custom_impl_Yolo.so" \
   "${SCRIPT_DIR}/deepstream-app-fish/libnvdsinfer_custom_impl_Yolo_cfd.so"

echo "=== Copied to deepstream-app-fish/libnvdsinfer_custom_impl_Yolo_cfd.so ==="

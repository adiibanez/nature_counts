#!/bin/bash
# Build the DeepStream-Yolo custom parser library for DS 6.4.
# Outputs libnvdsinfer_custom_impl_Yolo_cfd_ds64.so (distinct from DS 6.0 .so).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="ds64-yolo-builder"

# Step 1: Build (or reuse cached) builder image with TensorRT dev headers
echo "=== Building DS 6.4 builder image (cached after first run) ==="
docker build -t "${IMAGE_NAME}" -f "${SCRIPT_DIR}/Dockerfile.build-yolo-6.4" "${SCRIPT_DIR}"

# Step 2: Compile the parser .so with CUDA 12.2
echo "=== Compiling DeepStream-Yolo parser for DS 6.4 ==="
docker run --gpus all --rm \
  -v "${SCRIPT_DIR}/DeepStream-Yolo:/DeepStream-Yolo" \
  -w /DeepStream-Yolo \
  "${IMAGE_NAME}" \
  bash -c "CUDA_VER=12.2 make -C nvdsinfer_custom_impl_Yolo clean && CUDA_VER=12.2 make -C nvdsinfer_custom_impl_Yolo"

echo "=== Build complete ==="

# Step 3: Copy with _ds64 suffix (does not overwrite DS 6.0 .so)
cp "${SCRIPT_DIR}/DeepStream-Yolo/nvdsinfer_custom_impl_Yolo/libnvdsinfer_custom_impl_Yolo.so" \
   "${SCRIPT_DIR}/deepstream-app-fish/libnvdsinfer_custom_impl_Yolo_cfd_ds64.so"

echo "=== Copied to deepstream-app-fish/libnvdsinfer_custom_impl_Yolo_cfd_ds64.so ==="

#!/bin/bash
# Build the RF-DETR custom parser inside a DeepStream container.
# Run from the project root:
#   docker run --rm -v $(pwd)/deepstream-app-fish:/models \
#     nvcr.io/nvidia/deepstream:6.4-samples-multiarch \
#     bash /models/nvdsinfer_custom_impl_rfdetr/build_in_container.sh
#
# Or manually inside a running DeepStream container:
#   cd /models/nvdsinfer_custom_impl_rfdetr && make CUDA_VER=12.2 && make install

set -e
cd /models/nvdsinfer_custom_impl_rfdetr

# Detect CUDA version
CUDA_VER=$(ls /usr/local/ | grep -oP 'cuda-\K[0-9]+\.[0-9]+' | head -1)
echo "Building RF-DETR parser with CUDA ${CUDA_VER}..."

make clean
make CUDA_VER="${CUDA_VER}"
make install

echo "Built and installed libnvdsinfer_custom_impl_rfdetr.so to /models/"
ls -la /models/libnvdsinfer_custom_impl_rfdetr.so

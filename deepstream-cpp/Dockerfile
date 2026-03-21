FROM nvcr.io/nvidia/deepstream:6.4-samples-multiarch AS builder

# Build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    g++ \
    pkg-config \
    libglib2.0-dev \
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    libgstreamer-plugins-good1.0-dev \
    libopencv-dev \
    libssl-dev \
    zlib1g-dev \
    nlohmann-json3-dev \
    && rm -rf /var/lib/apt/lists/*

COPY . /build
WORKDIR /build

RUN mkdir -p build && cd build \
    && cmake .. \
       -DCMAKE_BUILD_TYPE=Release \
       -DDEEPSTREAM_DIR=/opt/nvidia/deepstream/deepstream-6.4 \
    && make -j$(nproc)

# ---------------------------------------------------------------------------
# Runtime image — keep it lean
# ---------------------------------------------------------------------------
FROM nvcr.io/nvidia/deepstream:6.4-samples-multiarch

# NVIDIA strips .so files from base image but leaves dpkg metadata, so apt
# thinks packages are installed. Force reinstall to get actual shared libs.
RUN apt-get update && apt-get install -y --reinstall --no-install-recommends \
    gstreamer1.0-rtsp \
    libgstrtspserver-1.0-0 \
    libopencv-core4.5d \
    libopencv-imgproc4.5d \
    libopencv-imgcodecs4.5d \
    libde265-0 \
    libx265-199 \
    libheif1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/build/ds_fish_pipeline /usr/local/bin/ds_fish_pipeline

ENV DS_CONFIG_DIR=/opt/nvidia/deepstream/deepstream-6.4/samples/configs/deepstream-app-fish
ENV PHOENIX_URL=ws://phoenix:4005/deepstream/websocket
ENV DEEPSTREAM_TOKEN=dev-secret-token

CMD ["ds_fish_pipeline"]

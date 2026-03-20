FROM nvcr.io/nvidia/deepstream:6.0.1-samples

# Fix expired NVIDIA repo key
RUN apt-key adv --fetch-keys https://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64/3bf863cc.pub

# Install Python3, pip, and GStreamer RTSP bindings
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-pip \
    python3-dev \
    python3-gi \
    python3-setuptools \
    python3-wheel \
    gir1.2-gst-rtsp-server-1.0 \
    libgstrtspserver-1.0-0 \
    gstreamer1.0-rtsp \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Install DeepStream Python bindings v1.1.1 for DS 6.0.1 (Python 3.6, x86_64)
RUN pip3 install --upgrade pip setuptools && \
    pip3 install \
    https://github.com/NVIDIA-AI-IOT/deepstream_python_apps/releases/download/v1.1.1/pyds-1.1.1-py3-none-linux_x86_64.whl

# Install Python dependencies
COPY requirements.txt /app/requirements.txt
RUN pip3 install --no-cache-dir -r /app/requirements.txt

COPY . /app
WORKDIR /app

ENV DS_CONFIG_DIR=/opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app-fish
ENV PHOENIX_URL=ws://phoenix:4005/deepstream/websocket
ENV DEEPSTREAM_TOKEN=dev-secret-token

CMD ["python3", "ds_fish_pipeline.py"]

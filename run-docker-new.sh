#!/bin/bash
# Launch DeepStream 6.0.1 with CFD YOLOv12x model - display mode (EglSink).
# Requires: xhost +local:docker on the host first.
docker run --gpus all -it --rm \
	--net=host \
	-v /tmp/.X11-unix:/tmp/.X11-unix \
	-e DISPLAY=$DISPLAY \
	-e XAUTHORITY=$XAUTHORITY \
	-v $HOME/.Xauthority:/root/.Xauthority:ro \
	-w /opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app-fish/ \
	-v /home/adrianibanez/projects/2022_naturecounts/videos:/videos \
	-v /home/adrianibanez/projects/2022_naturecounts/deepstream-app-fish/:/opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app-fish \
	nvcr.io/nvidia/deepstream:6.0.1-samples \
	deepstream-app -c /opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app-fish/test_cfd_singlevideo.txt

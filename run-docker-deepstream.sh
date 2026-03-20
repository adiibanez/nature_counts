docker run --gpus all  -it --rm -v /tmp/.X11-unix:/tmp/.X11-unix -p 8555:8554 \
	-w /opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app-fish/ \
	-v `pwd`/videos:/videos -v /home/adrianibanez/projects/2022_naturecounts/deepstream-app-fish/:/opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app-fish \
	-e DISPLAY=$DISPLAY nvcr.io/nvidia/deepstream:6.0.1-samples deepstream-app \
	-c /opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app-fish/test_tracker_yolofish.txt

#docker run --gpus all  -it --rm -v /tmp/.X11-unix:/tmp/.X11-unix -p 8555:8554 -v `pwd`/videos:/videos -v `pwd`/config/test_tracker.txt:/opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app/test_tracker.txt:rw  -e DISPLAY=$DISPLAY nvcr.io/nvidia/deepstream:6.0.1-samples

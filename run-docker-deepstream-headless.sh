docker run --gpus all  -it --rm -p 8555:8554 \
	-w /opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app-fish/ \
	-v `pwd`/videos:/videos -v /home/adrianibanez/projects/2022_naturecounts/deepstream-app-fish/:/opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app-fish \
	nvcr.io/nvidia/deepstream:6.0.1-samples deepstream-app \
	-c /opt/nvidia/deepstream/deepstream-6.0/samples/configs/deepstream-app-fish/test_tracker_yolofish_headless.txt


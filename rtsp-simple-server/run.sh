docker run -e RTSP_PROTOCOLS="tcp,udp" --rm -it -v `pwd`/rtsp-simple-server.yml:/rtsp-simple-server.yml -p 8554:8554 aler9/rtsp-simple-server

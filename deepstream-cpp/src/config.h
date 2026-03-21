#pragma once

#include <string>
#include <vector>

struct Config {
    // Muxer
    int muxer_width = 1920;
    int muxer_height = 1080;
    int muxer_batch_timeout = 4000;
    int gpu_id = 0;

    // Inference
    std::string infer_config;
    int infer_interval = 3;

    // Tracker
    int tracker_width = 640;
    int tracker_height = 384;
    std::string tracker_config;
    std::string tracker_lib;

    // Sources
    std::vector<std::string> source_uris;
    std::string rtsp_base_uri = "rtsp://mediamtx:8554/raw-cam";
    int num_sources = 1;
    bool file_loop = false;

    // RTSP output
    std::string rtsp_output_base = "rtsp://mediamtx:8554/cam";
    int rtsp_bitrate = 4000000;

    // Phoenix
    std::string phoenix_url = "ws://phoenix:4005/deepstream/websocket";
    std::string phoenix_token = "dev-secret-token";

    // Thumbnails
    bool enable_thumbnails = false;  // initial state, can be toggled at runtime via UI
    int thumb_size = 96;
    int thumb_max_rate = 2;
    int thumb_width = 480;
    int thumb_height = 270;

    // Labels
    std::vector<std::string> labels = {"fish"};
};

Config load_config();

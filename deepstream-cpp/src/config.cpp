#include "config.h"
#include <cstdlib>
#include <sstream>

static std::string env(const char* name, const char* fallback) {
    const char* val = std::getenv(name);
    return val ? std::string(val) : std::string(fallback);
}

static int env_int(const char* name, int fallback) {
    const char* val = std::getenv(name);
    return val ? std::atoi(val) : fallback;
}

Config load_config() {
    Config cfg;

    std::string ds_root = env("DS_ROOT", "/opt/nvidia/deepstream/deepstream-6.4");
    std::string config_dir = env("DS_CONFIG_DIR",
        (ds_root + "/samples/configs/deepstream-app-fish").c_str());

    cfg.infer_config = config_dir + "/config_infer_primary_cfd_yolov12_ds64.txt";
    cfg.tracker_config = config_dir + "/config_tracker_IOU.yml";
    cfg.tracker_lib = ds_root + "/lib/libnvds_nvmultiobjecttracker.so";

    cfg.num_sources = env_int("NUM_SOURCES", 1);
    cfg.rtsp_base_uri = env("RTSP_BASE_URI", "rtsp://mediamtx:8554/raw-cam");
    cfg.rtsp_output_base = env("RTSP_OUTPUT_BASE", "rtsp://mediamtx:8554/cam");
    cfg.rtsp_bitrate = env_int("RTSP_BITRATE", 4000000);
    cfg.file_loop = env_int("FILE_LOOP", 0) != 0;
    cfg.infer_interval = env_int("INFER_INTERVAL", 3);

    cfg.phoenix_url = env("PHOENIX_URL", "ws://phoenix:4005/deepstream/websocket");
    cfg.phoenix_token = env("DEEPSTREAM_TOKEN", "dev-secret-token");

    // Parse SOURCE_URIS (comma-separated) or generate from base URI
    std::string uris_str = env("SOURCE_URIS", "");
    if (!uris_str.empty()) {
        std::istringstream ss(uris_str);
        std::string uri;
        while (std::getline(ss, uri, ',')) {
            size_t start = uri.find_first_not_of(' ');
            size_t end = uri.find_last_not_of(' ');
            if (start != std::string::npos)
                cfg.source_uris.push_back(uri.substr(start, end - start + 1));
        }
    } else {
        for (int i = 0; i < cfg.num_sources; ++i)
            cfg.source_uris.push_back(cfg.rtsp_base_uri + std::to_string(i + 1));
    }

    return cfg;
}

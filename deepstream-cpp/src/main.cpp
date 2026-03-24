#include "config.h"
#include "pipeline.h"
#include "thumbnail.h"
#include "phoenix_client.h"
#include "probes.h"
#include "tracker_config.h"

#include <gst/gst.h>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <thread>
#include <atomic>

#define LOG(fmt, ...) fprintf(stderr, "[main] " fmt "\n", ##__VA_ARGS__)

static GMainLoop* g_main_loop = nullptr;
static std::atomic<bool> g_running{true};
static std::atomic<bool> g_config_changed{false};
static std::string g_config_dir;
static std::mutex g_config_mtx;
static std::string g_new_tracker_config;

static void signal_handler(int) {
    g_running = false;
    if (g_main_loop) g_main_loop_quit(g_main_loop);
}

static gboolean bus_callback(GstBus* /*bus*/, GstMessage* msg, gpointer data) {
    auto* loop = static_cast<GMainLoop*>(data);

    switch (GST_MESSAGE_TYPE(msg)) {
    case GST_MESSAGE_EOS:
        LOG("End of stream from %s", GST_MESSAGE_SRC_NAME(msg));
        g_main_loop_quit(loop);
        break;

    case GST_MESSAGE_ERROR: {
        GError* err = nullptr;
        gchar* debug = nullptr;
        gst_message_parse_error(msg, &err, &debug);

        const char* src_name = GST_MESSAGE_SRC_NAME(msg);
        bool is_per_source = strncmp(src_name, "source-", 7) == 0
                          || strncmp(src_name, "cpu-conv-", 9) == 0
                          || strncmp(src_name, "gpu-conv-", 9) == 0;

        if (is_per_source) {
            LOG("ERROR from %s (non-fatal, pipeline continues): %s\n  %s",
                src_name, err->message, debug ? debug : "");
        } else {
            LOG("ERROR from %s: %s\n  %s",
                src_name, err->message, debug ? debug : "");
            g_main_loop_quit(loop);
        }

        g_error_free(err);
        g_free(debug);
        break;
    }

    case GST_MESSAGE_WARNING: {
        GError* err = nullptr;
        gchar* debug = nullptr;
        gst_message_parse_warning(msg, &err, &debug);
        LOG("WARNING from %s: %s\n  %s",
            GST_MESSAGE_SRC_NAME(msg), err->message, debug ? debug : "");
        g_error_free(err);
        g_free(debug);
        break;
    }

    case GST_MESSAGE_STATE_CHANGED:
        if (GST_MESSAGE_SRC(msg) == data) break;  // only care about pipeline
        // Check if it's the pipeline element
        {
            GstState old_state, new_state, pending;
            gst_message_parse_state_changed(msg, &old_state, &new_state, &pending);
            // We'd need the pipeline pointer to compare — handled below
            (void)old_state; (void)new_state; (void)pending;
        }
        break;

    default:
        break;
    }
    return TRUE;
}

// Phoenix connection + detection push loop (runs in its own thread)
static void phoenix_thread_fn(const Config& cfg) {
    PhoenixClient phoenix(cfg.phoenix_url, cfg.phoenix_token);

    phoenix.set_command_callback([](const std::string& event, const json& payload) {
        if (event == "set_thumbnails") {
            bool enabled = payload.value("enabled", true);
            g_thumbnails_enabled.store(enabled, std::memory_order_relaxed);
            LOG("Thumbnails %s via runtime command", enabled ? "enabled" : "disabled");
        } else if (event == "set_crop_filters") {
            if (payload.contains("min_crop_area")) {
                int v = payload["min_crop_area"].get<int>();
                g_min_crop_area.store(v, std::memory_order_relaxed);
                LOG("min_crop_area set to %d", v);
            }
            if (payload.contains("min_sharpness")) {
                double v = payload["min_sharpness"].get<double>();
                g_min_sharpness.store(v, std::memory_order_relaxed);
                LOG("min_sharpness set to %.1f", v);
            }
        } else if (event == "set_tracker_config") {
            const std::string out_path = "/tmp/tracker_runtime.yml";
            if (write_tracker_yaml(payload, g_config_dir, out_path)) {
                std::lock_guard<std::mutex> lk(g_config_mtx);
                g_new_tracker_config = out_path;
                g_config_changed.store(true);
                if (g_main_loop) g_main_loop_quit(g_main_loop);
                LOG("Tracker config updated — restarting pipeline");
            }
        }
    });

    while (g_running) {
        try {
            phoenix.connect();
            LOG("Connected to Phoenix at %s", cfg.phoenix_url.c_str());

            while (g_running && phoenix.is_connected()) {
                json det;
                if (g_detection_queue.pop(det, 1000)) {
                    int cam_id = det.value("cam_id", -1);
                    phoenix.push_detections(cam_id, det);
                }
            }
        } catch (const std::exception& e) {
            LOG("Phoenix connection error: %s — retrying in 3s", e.what());
            for (int i = 0; i < 30 && g_running; ++i)
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    }

    phoenix.close();
}

int main(int argc, char* argv[]) {
    gst_init(&argc, &argv);

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    Config cfg = load_config();
    LOG("Loaded config: %zu sources, infer_interval=%d",
        cfg.source_uris.size(), cfg.infer_interval);

    // Store config dir for runtime tracker config writes
    {
        std::string ds_root = std::getenv("DS_ROOT")
            ? std::getenv("DS_ROOT")
            : "/opt/nvidia/deepstream/deepstream-6.4";
        const char* cd = std::getenv("DS_CONFIG_DIR");
        g_config_dir = cd ? cd : (ds_root + "/samples/configs/deepstream-app-fish");
    }

    // Phoenix pusher thread
    std::thread phoenix_thr(phoenix_thread_fn, std::cref(cfg));

    // GStreamer pipeline loop
    while (g_running) {
        // Apply pending tracker config change
        if (g_config_changed.load()) {
            std::lock_guard<std::mutex> lk(g_config_mtx);
            if (!g_new_tracker_config.empty()) {
                cfg.tracker_config = g_new_tracker_config;
                LOG("Using new tracker config: %s", cfg.tracker_config.c_str());
            }
            g_config_changed.store(false);
        }

        Pipeline pl = create_pipeline(cfg);
        g_main_loop = g_main_loop_new(nullptr, FALSE);

        GstBus* bus = gst_pipeline_get_bus(GST_PIPELINE(pl.pipeline));
        gst_bus_add_watch(bus, bus_callback, g_main_loop);
        gst_object_unref(bus);

        LOG("Setting pipeline to PLAYING");
        gst_element_set_state(pl.pipeline, GST_STATE_PLAYING);

        g_main_loop_run(g_main_loop);

        gst_element_set_state(pl.pipeline, GST_STATE_NULL);
        gst_object_unref(pl.pipeline);
        g_main_loop_unref(g_main_loop);
        g_main_loop = nullptr;

        LOG("Pipeline stopped");

        if (g_config_changed.load()) {
            LOG("Restarting pipeline with new tracker config...");
            std::this_thread::sleep_for(std::chrono::seconds(1));
            continue;
        }

        if (!cfg.file_loop || !g_running) break;

        LOG("Restarting pipeline...");
        std::this_thread::sleep_for(std::chrono::seconds(1));
    }

    // Cleanup
    g_running = false;
    phoenix_thr.join();

    LOG("Shutdown complete");
    return 0;
}

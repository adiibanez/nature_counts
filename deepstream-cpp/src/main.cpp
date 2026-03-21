#include "config.h"
#include "pipeline.h"
#include "thumbnail.h"
#include "phoenix_client.h"

#include <gst/gst.h>
#include <csignal>
#include <cstdio>
#include <thread>
#include <atomic>

#define LOG(fmt, ...) fprintf(stderr, "[main] " fmt "\n", ##__VA_ARGS__)

// Global thumbnail worker pointer (referenced by probes.cpp)
ThumbnailWorker* g_thumb_worker = nullptr;

static GMainLoop* g_main_loop = nullptr;
static std::atomic<bool> g_running{true};

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
        LOG("ERROR from %s: %s\n  %s",
            GST_MESSAGE_SRC_NAME(msg), err->message, debug ? debug : "");
        g_error_free(err);
        g_free(debug);
        g_main_loop_quit(loop);
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
            g_detection_queue.clear();
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

    // Thumbnail worker
    ThumbnailWorker thumb_worker(g_detection_queue, cfg.thumb_size);
    g_thumb_worker = &thumb_worker;
    thumb_worker.start();

    // Phoenix pusher thread
    std::thread phoenix_thr(phoenix_thread_fn, std::cref(cfg));

    // GStreamer pipeline loop
    while (g_running) {
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

        if (!cfg.file_loop || !g_running) break;

        LOG("Restarting pipeline...");
        std::this_thread::sleep_for(std::chrono::seconds(1));
    }

    // Cleanup
    g_running = false;
    thumb_worker.stop();
    g_thumb_worker = nullptr;
    phoenix_thr.join();

    LOG("Shutdown complete");
    return 0;
}

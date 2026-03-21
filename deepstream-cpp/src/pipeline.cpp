#include "pipeline.h"
#include "probes.h"
#include <cstdio>
#include <string>

#define LOG(fmt, ...) fprintf(stderr, "[Pipeline] " fmt "\n", ##__VA_ARGS__)

static GstElement* make_element(const char* factory, const char* name) {
    GstElement* elem = gst_element_factory_make(factory, name);
    if (!elem) {
        fprintf(stderr, "Failed to create element: %s (%s)\n", name, factory);
    }
    return elem;
}

static std::string fmt(const char* pattern, int i) {
    char buf[128];
    snprintf(buf, sizeof(buf), pattern, i);
    return std::string(buf);
}

// uridecodebin pad-added callback
struct PadAddedCtx {
    GstElement* cpu_conv;
};

static void on_pad_added(GstElement* src, GstPad* new_pad, gpointer user_data) {
    auto* ctx = static_cast<PadAddedCtx*>(user_data);
    GstCaps* caps = gst_pad_get_current_caps(new_pad);
    if (!caps) return;

    const gchar* name = gst_structure_get_name(gst_caps_get_structure(caps, 0));
    if (g_str_has_prefix(name, "video")) {
        GstPad* sink_pad = gst_element_get_static_pad(ctx->cpu_conv, "sink");
        if (!gst_pad_is_linked(sink_pad)) {
            GstPadLinkReturn ret = gst_pad_link(new_pad, sink_pad);
            LOG("Source %s: linked video pad (%d)", gst_element_get_name(src), ret);
        }
        gst_object_unref(sink_pad);
    }
    gst_caps_unref(caps);
}

// Per-camera appsink context (leaked intentionally — lives for pipeline lifetime)
struct AppsinkCtx {
    int cam_id;
};

Pipeline create_pipeline(const Config& cfg) {
    Pipeline result;
    int num_sources = static_cast<int>(cfg.source_uris.size());
    result.num_sources = num_sources;

    GstElement* pipeline = gst_pipeline_new("ds-fish-pipeline");
    result.pipeline = pipeline;

    // --- Streammux ---
    GstElement* mux = make_element("nvstreammux", "streammux");
    g_object_set(G_OBJECT(mux),
        "width", cfg.muxer_width,
        "height", cfg.muxer_height,
        "batch-size", num_sources,
        "batched-push-timeout", cfg.muxer_batch_timeout,
        "live-source", TRUE,
        "gpu-id", cfg.gpu_id,
        "enable-padding", TRUE,
        "nvbuf-memory-type", 3,  // CUDA_UNIFIED
        NULL);
    gst_bin_add(GST_BIN(pipeline), mux);

    // --- Sources ---
    // Leak PadAddedCtx on purpose — it must survive for the pipeline's lifetime
    for (int i = 0; i < num_sources; ++i) {
        LOG("Adding source %d: %s", i, cfg.source_uris[i].c_str());

        GstPad* sink_pad = gst_element_request_pad_simple(mux, fmt("sink_%d", i).c_str());

        GstElement* uridec = make_element("uridecodebin", fmt("source-%d", i).c_str());
        g_object_set(G_OBJECT(uridec), "uri", cfg.source_uris[i].c_str(), NULL);

        GstElement* cpu_conv = make_element("videoconvert", fmt("cpu-conv-%d", i).c_str());
        GstElement* gpu_conv = make_element("nvvideoconvert", fmt("gpu-conv-%d", i).c_str());
        g_object_set(G_OBJECT(gpu_conv),
            "gpu-id", cfg.gpu_id,
            "nvbuf-memory-type", 3,
            NULL);

        gst_bin_add_many(GST_BIN(pipeline), uridec, cpu_conv, gpu_conv, NULL);
        gst_element_link(cpu_conv, gpu_conv);

        GstPad* gpu_src = gst_element_get_static_pad(gpu_conv, "src");
        gst_pad_link(gpu_src, sink_pad);
        gst_object_unref(gpu_src);
        gst_object_unref(sink_pad);

        auto* pad_ctx = new PadAddedCtx{cpu_conv};
        g_signal_connect(uridec, "pad-added", G_CALLBACK(on_pad_added), pad_ctx);
    }

    // --- nvinfer ---
    GstElement* pgie = make_element("nvinfer", "primary-inference");
    g_object_set(G_OBJECT(pgie),
        "config-file-path", cfg.infer_config.c_str(),
        "batch-size", num_sources,
        "interval", cfg.infer_interval,
        "gpu-id", cfg.gpu_id,
        "unique-id", 1,
        NULL);
    gst_bin_add(GST_BIN(pipeline), pgie);

    // --- Tracker ---
    GstElement* tracker = make_element("nvtracker", "tracker");
    g_object_set(G_OBJECT(tracker),
        "tracker-width", cfg.tracker_width,
        "tracker-height", cfg.tracker_height,
        "ll-lib-file", cfg.tracker_lib.c_str(),
        "ll-config-file", cfg.tracker_config.c_str(),
        "gpu-id", cfg.gpu_id,
        "display-tracking-id", TRUE,
        NULL);
    gst_bin_add(GST_BIN(pipeline), tracker);

    // --- Demux ---
    GstElement* demux = make_element("nvstreamdemux", "demux");
    gst_bin_add(GST_BIN(pipeline), demux);

    // --- Link core ---
    gst_element_link(mux, pgie);
    gst_element_link(pgie, tracker);
    gst_element_link(tracker, demux);

    // --- Tracker probe for metadata extraction ---
    install_tracker_probe(tracker, cfg);
    LOG("Tracker metadata probe installed");

    // --- Per-camera branches ---
    for (int i = 0; i < num_sources; ++i) {
        std::string rtsp_url = cfg.rtsp_output_base + std::to_string(i + 1);
        LOG("Branch %d: demux -> osd -> tee -> enc+thumb -> %s", i, rtsp_url.c_str());

        GstElement* q       = make_element("queue",            fmt("q-%d", i).c_str());
        GstElement* osd     = make_element("nvdsosd",          fmt("osd-%d", i).c_str());
        GstElement* tee     = make_element("tee",              fmt("tee-%d", i).c_str());

        g_object_set(G_OBJECT(osd),
            "display-text", TRUE,
            "display-bbox", TRUE,
            "display-mask", FALSE,
            NULL);

        gst_bin_add_many(GST_BIN(pipeline), q, osd, tee, NULL);

        // Link demux -> q -> osd -> tee
        GstPad* demux_pad = gst_element_request_pad_simple(demux, fmt("src_%d", i).c_str());
        GstPad* q_sink = gst_element_get_static_pad(q, "sink");
        gst_pad_link(demux_pad, q_sink);
        gst_object_unref(demux_pad);
        gst_object_unref(q_sink);

        gst_element_link(q, osd);
        gst_element_link(osd, tee);

        // === Render branch: tee -> q -> conv(I420) -> enc -> parse -> rtspclientsink ===
        GstElement* q_render = make_element("queue",             fmt("q-render-%d", i).c_str());
        GstElement* conv     = make_element("nvvideoconvert",    fmt("conv-%d", i).c_str());
        GstElement* capsf    = make_element("capsfilter",        fmt("caps-%d", i).c_str());
        GstElement* enc      = make_element("nvv4l2h264enc",     fmt("enc-%d", i).c_str());
        GstElement* parse    = make_element("h264parse",         fmt("parse-%d", i).c_str());
        GstElement* rtsp_sink = make_element("rtspclientsink",   fmt("rtsp-sink-%d", i).c_str());

        g_object_set(G_OBJECT(conv), "gpu-id", cfg.gpu_id, NULL);

        GstCaps* i420_caps = gst_caps_from_string("video/x-raw(memory:NVMM), format=I420");
        g_object_set(G_OBJECT(capsf), "caps", i420_caps, NULL);
        gst_caps_unref(i420_caps);

        g_object_set(G_OBJECT(enc),
            "bitrate", static_cast<guint>(cfg.rtsp_bitrate),
            "iframeinterval", 15,
            NULL);
        g_object_set(G_OBJECT(parse), "config-interval", -1, NULL);
        g_object_set(G_OBJECT(rtsp_sink),
            "location", rtsp_url.c_str(),
            "protocols", 4,  // TCP
            NULL);

        gst_bin_add_many(GST_BIN(pipeline),
            q_render, conv, capsf, enc, parse, rtsp_sink, NULL);

        gst_element_link(tee, q_render);
        gst_element_link_many(q_render, conv, capsf, enc, parse, rtsp_sink, NULL);

        // === Thumbnail branch: tee -> q(leaky) -> videorate -> conv(RGBA) -> appsink ===
        GstElement* q_thumb    = make_element("queue",            fmt("q-thumb-%d", i).c_str());
        GstElement* thumb_rate = make_element("videorate",        fmt("thumb-rate-%d", i).c_str());
        GstElement* thumb_conv = make_element("nvvideoconvert",   fmt("thumb-conv-%d", i).c_str());
        GstElement* thumb_caps = make_element("capsfilter",       fmt("thumb-caps-%d", i).c_str());
        GstElement* appsink    = make_element("appsink",          fmt("thumb-sink-%d", i).c_str());

        g_object_set(G_OBJECT(q_thumb),
            "max-size-buffers", 2u,
            "leaky", 2,  // downstream
            NULL);
        g_object_set(G_OBJECT(thumb_rate),
            "drop-only", TRUE,
            "max-rate", cfg.thumb_max_rate,
            NULL);
        g_object_set(G_OBJECT(thumb_conv), "gpu-id", cfg.gpu_id, NULL);

        char caps_str[256];
        snprintf(caps_str, sizeof(caps_str),
            "video/x-raw, format=RGBA, width=%d, height=%d",
            cfg.thumb_width, cfg.thumb_height);
        GstCaps* rgba_caps = gst_caps_from_string(caps_str);
        g_object_set(G_OBJECT(thumb_caps), "caps", rgba_caps, NULL);
        gst_caps_unref(rgba_caps);

        g_object_set(G_OBJECT(appsink),
            "emit-signals", TRUE,
            "drop", TRUE,
            "max-buffers", 1u,
            "sync", FALSE,
            NULL);

        auto* app_ctx = new AppsinkCtx{i};
        g_signal_connect(appsink, "new-sample",
                         G_CALLBACK(appsink_new_sample), app_ctx);

        gst_bin_add_many(GST_BIN(pipeline),
            q_thumb, thumb_rate, thumb_conv, thumb_caps, appsink, NULL);

        gst_element_link(tee, q_thumb);
        gst_element_link_many(q_thumb, thumb_rate, thumb_conv, thumb_caps, appsink, NULL);
    }

    return result;
}

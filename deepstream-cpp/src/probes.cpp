#include "probes.h"
#include "thumbnail.h"

#include <gst/app/gstappsink.h>
#include <gstnvdsmeta.h>
#include <nvbufsurface.h>

#include <mutex>
#include <unordered_map>
#include <cstring>
#include <ctime>

// Shared state between tracker probe and appsink callbacks
static std::mutex g_det_lock;
static std::unordered_map<int, json> g_pending_detections;

// Reference to config labels (set during install)
static const Config* g_cfg = nullptr;

// Thumbnail worker (owned by main, set during install)
extern ThumbnailWorker* g_thumb_worker;

static GstPadProbeReturn tracker_src_probe(
    GstPad* /*pad*/, GstPadProbeInfo* info, gpointer /*user_data*/)
{
    GstBuffer* buf = GST_PAD_PROBE_INFO_BUFFER(info);
    if (!buf) return GST_PAD_PROBE_OK;

    NvDsBatchMeta* batch_meta = gst_buffer_get_nvds_batch_meta(buf);
    if (!batch_meta) return GST_PAD_PROBE_OK;

    for (NvDsMetaList* l_frame = batch_meta->frame_meta_list;
         l_frame != nullptr; l_frame = l_frame->next)
    {
        auto* frame_meta = static_cast<NvDsFrameMeta*>(l_frame->data);
        int source_id = frame_meta->source_id;
        guint64 pts = frame_meta->buf_pts;

        json objects = json::array();

        for (NvDsMetaList* l_obj = frame_meta->obj_meta_list;
             l_obj != nullptr; l_obj = l_obj->next)
        {
            auto* obj_meta = static_cast<NvDsObjectMeta*>(l_obj->data);
            int class_id = obj_meta->class_id;
            const char* label = (class_id < static_cast<int>(g_cfg->labels.size()))
                ? g_cfg->labels[class_id].c_str() : "object";

            auto& rect = obj_meta->rect_params;

            objects.push_back({
                {"track_id",   static_cast<uint64_t>(obj_meta->object_id)},
                {"class_id",   class_id},
                {"label",      label},
                {"confidence", static_cast<double>(
                    static_cast<int>(obj_meta->confidence * 1000.0f + 0.5f)) / 1000.0},
                {"bbox", {
                    {"left",   static_cast<double>(
                        static_cast<int>(rect.left * 10.0f + 0.5f)) / 10.0},
                    {"top",    static_cast<double>(
                        static_cast<int>(rect.top * 10.0f + 0.5f)) / 10.0},
                    {"width",  static_cast<double>(
                        static_cast<int>(rect.width * 10.0f + 0.5f)) / 10.0},
                    {"height", static_cast<double>(
                        static_cast<int>(rect.height * 10.0f + 0.5f)) / 10.0},
                }},
            });
        }

        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        int64_t now_ms = static_cast<int64_t>(ts.tv_sec) * 1000
                       + ts.tv_nsec / 1000000;

        json det = {
            {"cam_id",     source_id},
            {"ts",         now_ms},
            {"pts",        pts},
            {"resolution", {
                {"width",  frame_meta->source_frame_width},
                {"height", frame_meta->source_frame_height},
            }},
            {"objects",    std::move(objects)},
        };

        std::lock_guard<std::mutex> lk(g_det_lock);
        g_pending_detections[source_id] = std::move(det);
    }

    return GST_PAD_PROBE_OK;
}

void install_tracker_probe(GstElement* tracker, const Config& cfg) {
    g_cfg = &cfg;
    GstPad* src_pad = gst_element_get_static_pad(tracker, "src");
    gst_pad_add_probe(src_pad, GST_PAD_PROBE_TYPE_BUFFER,
                      tracker_src_probe, nullptr, nullptr);
    gst_object_unref(src_pad);
}

GstFlowReturn appsink_new_sample(GstElement* appsink, gpointer user_data) {
    // user_data points to a struct { int cam_id; } allocated by pipeline.cpp
    struct AppsinkCtx { int cam_id; };
    auto* ctx = static_cast<AppsinkCtx*>(user_data);
    int cam_id = ctx->cam_id;

    GstSample* sample = gst_app_sink_pull_sample(GST_APP_SINK(appsink));
    if (!sample) return GST_FLOW_OK;

    // Grab pending detection for this camera
    json det;
    {
        std::lock_guard<std::mutex> lk(g_det_lock);
        auto it = g_pending_detections.find(cam_id);
        if (it == g_pending_detections.end()) {
            gst_sample_unref(sample);
            return GST_FLOW_OK;
        }
        det = std::move(it->second);
        g_pending_detections.erase(it);
    }

    GstBuffer* buf = gst_sample_get_buffer(sample);
    GstCaps* caps = gst_sample_get_caps(sample);
    GstStructure* s = gst_caps_get_structure(caps, 0);

    int width = 0, height = 0;
    gst_structure_get_int(s, "width", &width);
    gst_structure_get_int(s, "height", &height);

    GstMapInfo map;
    if (!gst_buffer_map(buf, &map, GST_MAP_READ)) {
        // Push detection without thumbnails
        g_detection_queue.push(std::move(det));
        gst_sample_unref(sample);
        return GST_FLOW_OK;
    }

    // Fast copy — release GStreamer buffer immediately
    ThumbnailJob job;
    job.rgba_frame.resize(map.size);
    std::memcpy(job.rgba_frame.data(), map.data, map.size);
    gst_buffer_unmap(buf, &map);
    gst_sample_unref(sample);

    job.frame_width = width;
    job.frame_height = height;
    job.source_width = det.value("resolution", json::object()).value("width", g_cfg->muxer_width);
    job.source_height = det.value("resolution", json::object()).value("height", g_cfg->muxer_height);
    job.detection = std::move(det);

    if (g_thumb_worker && !g_thumb_worker->submit(std::move(job))) {
        // Worker overloaded — push without thumbnails
        g_detection_queue.push(std::move(job.detection));
    }

    return GST_FLOW_OK;
}

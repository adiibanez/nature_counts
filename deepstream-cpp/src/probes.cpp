#include "probes.h"
#include "thumbnail.h"

#include <gstnvdsmeta.h>

#include <atomic>
#include <ctime>
#include <unordered_map>

// Runtime toggle — can be flipped by Phoenix command
std::atomic<bool> g_thumbnails_enabled{true};

static const Config* g_cfg = nullptr;
static std::unordered_map<int, int> g_frame_count;

static GstPadProbeReturn tracker_src_probe(
    GstPad* /*pad*/, GstPadProbeInfo* info, gpointer /*user_data*/)
{
    if (!g_thumbnails_enabled.load(std::memory_order_relaxed))
        return GST_PAD_PROBE_OK;

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

        // Rate limit: ~2 pushes per second per source
        int& fc = g_frame_count[source_id];
        fc++;
        if (fc % 15 != 0) continue;

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

        g_detection_queue.push(std::move(det));
    }

    return GST_PAD_PROBE_OK;
}

void install_tracker_probe(GstElement* tracker, const Config& cfg) {
    g_cfg = &cfg;
    g_thumbnails_enabled.store(cfg.enable_thumbnails);
    GstPad* src_pad = gst_element_get_static_pad(tracker, "src");
    gst_pad_add_probe(src_pad, GST_PAD_PROBE_TYPE_BUFFER,
                      tracker_src_probe, nullptr, nullptr);
    gst_object_unref(src_pad);
}

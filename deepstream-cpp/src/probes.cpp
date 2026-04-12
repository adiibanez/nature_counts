#include "probes.h"
#include "thumbnail.h"

#include <gstnvdsmeta.h>
#include <nvdsmeta.h>
#include <nvll_osd_struct.h>

#include <algorithm>
#include <atomic>
#include <ctime>
#include <unordered_map>

// Runtime toggle — can be flipped by Phoenix command
std::atomic<bool> g_thumbnails_enabled{true};
std::atomic<int> g_min_crop_area{2500};
std::atomic<double> g_min_sharpness{0.0};

static const Config* g_cfg = nullptr;
static std::unordered_map<int, int64_t> g_last_push_ms;

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

        // --- OSD label styling (runs on EVERY frame) ---
        for (NvDsMetaList* l_obj = frame_meta->obj_meta_list;
             l_obj != nullptr; l_obj = l_obj->next)
        {
            auto* obj_meta = static_cast<NvDsObjectMeta*>(l_obj->data);
            int class_id = obj_meta->class_id;
            const char* lbl = (class_id < static_cast<int>(g_cfg->labels.size()))
                ? g_cfg->labels[class_id].c_str() : "object";

            char txt[64];
            float conf = obj_meta->confidence;
            if (conf >= 0.0f)
                snprintf(txt, sizeof(txt), "%s #%lu %.0f%%",
                         lbl, obj_meta->object_id, conf * 100.0f);
            else
                snprintf(txt, sizeof(txt), "%s #%lu",
                         lbl, obj_meta->object_id);

            // Zero the struct to avoid freeing unknown pointers, then populate.
            memset(&obj_meta->text_params, 0, sizeof(obj_meta->text_params));
            auto& tp = obj_meta->text_params;
            tp.display_text = g_strdup(txt);
            tp.x_offset = static_cast<int>(obj_meta->rect_params.left);
            tp.y_offset = std::max(0, static_cast<int>(obj_meta->rect_params.top) - 28);
            tp.font_params.font_name = g_strdup("Sans Bold");
            tp.font_params.font_size = 18;
            tp.font_params.font_color = {1.0, 1.0, 1.0, 1.0};  // white
            tp.set_bg_clr = 1;
            tp.text_bg_clr = {0.0, 0.0, 0.0, 0.6};  // semi-transparent black
        }

        // --- Rate-limited Phoenix push (~2/sec per source) ---
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        int64_t now_ms = static_cast<int64_t>(ts.tv_sec) * 1000
                       + ts.tv_nsec / 1000000;

        int64_t& last_ms = g_last_push_ms[source_id];
        if (now_ms - last_ms < 500) continue;
        last_ms = now_ms;

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
    g_min_crop_area.store(cfg.min_crop_area);
    g_min_sharpness.store(cfg.min_sharpness);
    GstPad* src_pad = gst_element_get_static_pad(tracker, "src");
    gst_pad_add_probe(src_pad, GST_PAD_PROBE_TYPE_BUFFER,
                      tracker_src_probe, nullptr, nullptr);
    gst_object_unref(src_pad);
}

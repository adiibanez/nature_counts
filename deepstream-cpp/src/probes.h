#pragma once

#include <gst/gst.h>
#include <atomic>
#include "config.h"

// Runtime toggle for thumbnail generation (set via Phoenix command or env var)
extern std::atomic<bool> g_thumbnails_enabled;

// Runtime crop quality thresholds (set via Phoenix command or env var)
extern std::atomic<int> g_min_crop_area;
extern std::atomic<double> g_min_sharpness;

// Install the tracker src pad probe. Must be called after pipeline construction.
// Extracts detection metadata and thumbnail crops directly from the GPU buffer
// using NvBufSurfTransform (no separate GStreamer branch needed).
void install_tracker_probe(GstElement* tracker, const Config& cfg);

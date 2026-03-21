#pragma once

#include <gst/gst.h>
#include <atomic>
#include "config.h"

// Runtime toggle for thumbnail generation (set via Phoenix command or env var)
extern std::atomic<bool> g_thumbnails_enabled;

// Install the tracker src pad probe. Must be called after pipeline construction.
void install_tracker_probe(GstElement* tracker, const Config& cfg);

// Create a new-sample callback for per-camera appsink thumbnail extraction.
// Returns a GCallback suitable for g_signal_connect("new-sample", ...).
GstFlowReturn appsink_new_sample(GstElement* appsink, gpointer user_data);

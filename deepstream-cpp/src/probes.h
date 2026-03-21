#pragma once

#include <gst/gst.h>
#include "config.h"

// Install the tracker src pad probe. Must be called after pipeline construction.
void install_tracker_probe(GstElement* tracker, const Config& cfg);

// Create a new-sample callback for per-camera appsink thumbnail extraction.
// Returns a GCallback suitable for g_signal_connect("new-sample", ...).
GstFlowReturn appsink_new_sample(GstElement* appsink, gpointer user_data);

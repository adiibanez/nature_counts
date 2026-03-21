#pragma once

#include <gst/gst.h>
#include "config.h"

struct Pipeline {
    GstElement* pipeline = nullptr;
    int num_sources = 0;
};

Pipeline create_pipeline(const Config& cfg);

/*
 * Custom DeepStream bbox parser for RF-DETR (Detection Transformer).
 *
 * RF-DETR outputs two tensors:
 *   - "scores": shape [batch, num_queries, num_classes] — class logits (post-sigmoid)
 *   - "boxes":  shape [batch, num_queries, 4] — bbox coords in cxcywh normalized [0,1]
 *
 * Unlike YOLO, DETR uses set prediction — no NMS needed.
 * Set cluster-mode=4 in the DeepStream config to disable NMS.
 */

#include "nvdsinfer_custom_impl.h"

#include <cmath>
#include <cstring>
#include <vector>
#include <iostream>
#include <algorithm>

extern "C" bool
NvDsInferParseRFDETR(std::vector<NvDsInferLayerInfo> const& outputLayersInfo,
    NvDsInferNetworkInfo const& networkInfo,
    NvDsInferParseDetectionParams const& detectionParams,
    std::vector<NvDsInferParseObjectInfo>& objectList);

static inline float clamp(float val, float lo, float hi) {
    return std::max(lo, std::min(val, hi));
}

static bool
NvDsInferParseCustomRFDETR(std::vector<NvDsInferLayerInfo> const& outputLayersInfo,
    NvDsInferNetworkInfo const& networkInfo,
    NvDsInferParseDetectionParams const& detectionParams,
    std::vector<NvDsInferParseObjectInfo>& objectList)
{
    if (outputLayersInfo.size() < 2) {
        std::cerr << "ERROR: RF-DETR parser expects 2 output layers (scores, boxes), got "
                  << outputLayersInfo.size() << std::endl;
        return false;
    }

    // Identify scores and boxes tensors by shape heuristic:
    // scores: [num_queries, num_classes]  (last dim is small, e.g. 1-80)
    // boxes:  [num_queries, 4]            (last dim is exactly 4)
    const NvDsInferLayerInfo* scores_layer = nullptr;
    const NvDsInferLayerInfo* boxes_layer = nullptr;

    for (auto& layer : outputLayersInfo) {
        uint last_dim = layer.inferDims.d[layer.inferDims.numDims - 1];
        if (last_dim == 4) {
            boxes_layer = &layer;
        } else {
            scores_layer = &layer;
        }
    }

    if (!scores_layer || !boxes_layer) {
        // Fallback: assume layer 0 = scores, layer 1 = boxes
        scores_layer = &outputLayersInfo[0];
        boxes_layer = &outputLayersInfo[1];
    }

    // Extract dimensions
    uint num_queries = boxes_layer->inferDims.d[0];
    uint num_classes = scores_layer->inferDims.d[scores_layer->inferDims.numDims - 1];

    const float* scores = static_cast<const float*>(scores_layer->buffer);
    const float* boxes = static_cast<const float*>(boxes_layer->buffer);

    float netW = static_cast<float>(networkInfo.width);
    float netH = static_cast<float>(networkInfo.height);

    for (uint q = 0; q < num_queries; ++q) {
        // Find the class with highest score for this query
        const float* class_scores = scores + q * num_classes;
        int best_class = 0;
        float best_score = class_scores[0];

        for (uint c = 1; c < num_classes; ++c) {
            if (class_scores[c] > best_score) {
                best_score = class_scores[c];
                best_class = static_cast<int>(c);
            }
        }

        // Apply threshold
        if (best_class >= static_cast<int>(detectionParams.perClassPreclusterThreshold.size()))
            continue;
        if (best_score < detectionParams.perClassPreclusterThreshold[best_class])
            continue;

        // Decode bbox: RF-DETR outputs cxcywh normalized [0,1]
        float cx = boxes[q * 4 + 0];
        float cy = boxes[q * 4 + 1];
        float w  = boxes[q * 4 + 2];
        float h  = boxes[q * 4 + 3];

        // Convert to absolute pixel coords (xyxy)
        float x1 = (cx - w / 2.0f) * netW;
        float y1 = (cy - h / 2.0f) * netH;
        float x2 = (cx + w / 2.0f) * netW;
        float y2 = (cy + h / 2.0f) * netH;

        // Clamp to network dimensions
        x1 = clamp(x1, 0.0f, netW);
        y1 = clamp(y1, 0.0f, netH);
        x2 = clamp(x2, 0.0f, netW);
        y2 = clamp(y2, 0.0f, netH);

        float bw = x2 - x1;
        float bh = y2 - y1;

        if (bw < 1.0f || bh < 1.0f)
            continue;

        NvDsInferParseObjectInfo obj;
        obj.left = x1;
        obj.top = y1;
        obj.width = bw;
        obj.height = bh;
        obj.detectionConfidence = best_score;
        obj.classId = best_class;

        objectList.push_back(obj);
    }

    return true;
}

extern "C" bool
NvDsInferParseRFDETR(std::vector<NvDsInferLayerInfo> const& outputLayersInfo,
    NvDsInferNetworkInfo const& networkInfo,
    NvDsInferParseDetectionParams const& detectionParams,
    std::vector<NvDsInferParseObjectInfo>& objectList)
{
    return NvDsInferParseCustomRFDETR(outputLayersInfo, networkInfo, detectionParams, objectList);
}

CHECK_CUSTOM_PARSE_FUNC_PROTOTYPE(NvDsInferParseRFDETR);

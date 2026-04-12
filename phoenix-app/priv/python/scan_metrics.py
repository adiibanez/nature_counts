#!/usr/bin/env python3
"""
Scan a single video file for metrics. Writes a .metrics.json sidecar.

Usage: python3 scan_metrics.py <video_path> <model_path> <sample_frames>

Exits 0 on success, 1 on error. Prints JSON result to stdout.
"""
import sys
import os
import json
import cv2
import numpy as np
from datetime import datetime, timezone

def scan_video(video_path, model_path, sample_frames):
    from detectors import create_detector

    SIDECAR_SUFFIX = ".metrics.json"

    if not os.path.isfile(video_path):
        return {"error": f"File not found: {video_path}"}

    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        metrics = {"schema_version": 2, "error": "could not read video"}
        _write_sidecar(video_path, metrics, SIDECAR_SUFFIX)
        cap.release()
        return {"status": "error", "file": os.path.basename(video_path), "reason": "could not read"}

    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    fps_val = cap.get(cv2.CAP_PROP_FPS)
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    duration = total_frames / fps_val if fps_val > 0 else 0

    # Sample frames — evenly spaced across the middle 90%
    start_f = int(total_frames * 0.05)
    end_f = int(total_frames * 0.95)
    if end_f <= start_f:
        start_f, end_f = 0, max(total_frames - 1, 0)

    n = sample_frames
    positions = [start_f + i * (end_f - start_f) // max(n - 1, 1) for i in range(n)]

    frames = []
    frame_positions = []
    for pos in positions:
        cap.set(cv2.CAP_PROP_POS_FRAMES, pos)
        ret, frame = cap.read()
        if ret:
            frames.append(frame)
            frame_positions.append(pos)
    cap.release()

    if not frames:
        metrics = {"schema_version": 2, "error": "no frames could be read"}
        _write_sidecar(video_path, metrics, SIDECAR_SUFFIX)
        return {"status": "error", "file": os.path.basename(video_path), "reason": "no frames"}

    # Load model
    model = create_detector(model_path)

    all_areas = []
    all_confidences = []
    total_detections = 0
    brightness_values = []
    contrast_values = []
    grays = []
    per_frame_detections = []
    per_frame_max_conf = []
    per_frame_class_ids = []
    edge_density_values = []
    color_saturation_values = []

    for frame in frames:
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        grays.append(gray)
        brightness_values.append(float(np.mean(gray)))
        contrast_values.append(float(np.std(gray)))

        # Edge density
        edges = cv2.Canny(gray, 50, 150)
        edge_density_values.append(round(float(np.count_nonzero(edges)) / edges.size * 100, 2))

        # Color saturation
        hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
        color_saturation_values.append(round(float(np.mean(hsv[:, :, 1])), 1))

        frame_det_count = 0
        frame_max_conf = 0.0
        frame_classes = set()
        xyxy, confs, cls_ids = model.predict(frame, imgsz=640, conf=0.15)
        if len(xyxy) > 0:
            frame_det_count = len(xyxy)
            frame_max_conf = float(confs.max())
            all_confidences.extend(confs.tolist())
            frame_classes.update(cls_ids.tolist())
            for box in xyxy:
                x1, y1, x2, y2 = box[:4]
                area = int((x2 - x1) * (y2 - y1))
                all_areas.append(area)
        total_detections += frame_det_count
        per_frame_detections.append(frame_det_count)
        per_frame_max_conf.append(round(frame_max_conf, 2))
        per_frame_class_ids.append(sorted(frame_classes))

    # Motion score
    motion_diffs = []
    for i in range(1, len(grays)):
        diff = cv2.absdiff(grays[i - 1], grays[i])
        motion_diffs.append(float(np.mean(diff)))

    n_sampled = len(frames)
    avg_det = total_detections / n_sampled if n_sampled > 0 else 0
    avg_brightness = round(sum(brightness_values) / len(brightness_values), 1) if brightness_values else 0
    avg_contrast = round(sum(contrast_values) / len(contrast_values), 1) if contrast_values else 0
    motion_score = round(sum(motion_diffs) / len(motion_diffs), 2) if motion_diffs else 0
    avg_edge_density = round(sum(edge_density_values) / len(edge_density_values), 2) if edge_density_values else 0
    avg_saturation = round(sum(color_saturation_values) / len(color_saturation_values), 1) if color_saturation_values else 0
    avg_confidence = round(sum(all_confidences) / len(all_confidences), 2) if all_confidences else 0

    all_class_ids = set()
    for cids in per_frame_class_ids:
        all_class_ids.update(cids)

    det_std = round(float(np.std(per_frame_detections)), 2) if per_frame_detections else 0
    peak_detections = max(per_frame_detections) if per_frame_detections else 0

    # Per-sample temporal data
    samples = []
    for si in range(n_sampled):
        ts = round(frame_positions[si] / fps_val, 1) if fps_val > 0 else 0
        mot = motion_diffs[si - 1] if si > 0 and si - 1 < len(motion_diffs) else 0
        samples.append({
            "t": ts,
            "det": per_frame_detections[si],
            "bright": round(brightness_values[si], 1),
            "contrast": round(contrast_values[si], 1),
            "motion": round(mot, 2),
            "conf": per_frame_max_conf[si],
            "edge": edge_density_values[si],
            "sat": color_saturation_values[si],
        })

    metrics = {
        "schema_version": 2,
        "total_frames": total_frames,
        "fps": round(fps_val, 2),
        "duration_s": round(duration, 1),
        "resolution": f"{width}x{height}",
        "sampled_frames": n_sampled,
        "total_detections": total_detections,
        "avg_detections_per_frame": round(avg_det, 1),
        "peak_detections": peak_detections,
        "det_std": det_std,
        "avg_brightness": avg_brightness,
        "contrast": avg_contrast,
        "motion_score": motion_score,
        "edge_density": avg_edge_density,
        "saturation": avg_saturation,
        "avg_confidence": avg_confidence,
        "class_ids": sorted(all_class_ids),
        "scanned_at": datetime.now(timezone.utc).isoformat(),
        "samples": samples,
        "bbox_areas": {
            "count": len(all_areas),
            "min": min(all_areas) if all_areas else 0,
            "max": max(all_areas) if all_areas else 0,
            "mean": round(sum(all_areas) / len(all_areas)) if all_areas else 0,
        },
    }

    _write_sidecar(video_path, metrics, SIDECAR_SUFFIX)
    return {"status": "ok", "file": os.path.basename(video_path)}


def _write_sidecar(video_path, metrics, suffix):
    sidecar_path = video_path + suffix
    tmp_path = sidecar_path + ".tmp"
    with open(tmp_path, "w") as f:
        json.dump(metrics, f, indent=2)
    os.replace(tmp_path, sidecar_path)


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(json.dumps({"error": "Usage: scan_metrics.py <video_path> <model_path> <sample_frames>"}))
        sys.exit(1)

    video_path = sys.argv[1]
    model_path = sys.argv[2]
    sample_frames = int(sys.argv[3])

    try:
        result = scan_video(video_path, model_path, sample_frames)
        print(json.dumps(result))
        sys.exit(0 if result.get("status") == "ok" else 1)
    except Exception as e:
        print(json.dumps({"error": str(e), "file": os.path.basename(video_path)}))
        sys.exit(1)

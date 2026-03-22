#!/usr/bin/env python3
"""
Offline fish detection + tracking pipeline.

Reads a video file, runs YOLO detection, applies ByteTrack tracking,
and outputs JSONL to stdout (one line per track summary).

Usage:
    python detect.py --video /path/to/video.mp4 --profile '{"fps":3,...}'

Output (JSONL, one line per track):
    {"track_id": 1, "first_frame": 10, "last_frame": 200, "frame_count": 45,
     "best_confidence": 0.92, "best_bbox_area": 8500,
     "crop_b64": "base64...", "bbox": [x1,y1,x2,y2]}

Signals progress on stderr:
    PROGRESS:20
    PROGRESS:50
"""

import argparse
import base64
import json
import sys
from collections import defaultdict
from pathlib import Path

import cv2
import numpy as np
from ultralytics import YOLO

# supervision provides ByteTrack
import supervision as sv


def extract_frames(video_path: str, fps: float):
    """Yield (frame_idx, frame) at the requested FPS."""
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"Cannot open video: {video_path}")

    video_fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    step = max(1, int(video_fps / fps))

    frame_idx = 0
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        if frame_idx % step == 0:
            yield frame_idx, frame, total_frames
        frame_idx += 1

    cap.release()


def crop_and_encode(frame, bbox, quality=85):
    """Crop bbox from frame and return base64 JPEG."""
    x1, y1, x2, y2 = [int(v) for v in bbox]
    h, w = frame.shape[:2]
    x1, y1 = max(0, x1), max(0, y1)
    x2, y2 = min(w, x2), min(h, y2)
    crop = frame[y1:y2, x1:x2]
    if crop.size == 0:
        return None
    _, buf = cv2.imencode(".jpg", crop, [cv2.IMWRITE_JPEG_QUALITY, quality])
    return base64.b64encode(buf).decode("ascii")


def progress(pct: int):
    print(f"PROGRESS:{pct}", file=sys.stderr, flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--video", required=True)
    parser.add_argument("--profile", required=True, help="JSON profile config")
    parser.add_argument("--model", default=None, help="Path to YOLO model")
    args = parser.parse_args()

    profile = json.loads(args.profile)
    fps = profile.get("fps", 3)
    imgsz = profile.get("imgsz", 640)
    conf_threshold = profile.get("detection_threshold", 0.15)
    min_bbox_area = profile.get("min_bbox_area", 4096)

    # Load model
    model_path = args.model or "yolov8n.pt"  # fallback; real path passed from Elixir
    model = YOLO(model_path)

    # ByteTrack tracker
    tracker = sv.ByteTrack(
        track_activation_threshold=conf_threshold,
        minimum_matching_threshold=0.8,
        frame_rate=int(fps),
    )

    # Per-track state: accumulate best crop info
    track_state = defaultdict(lambda: {
        "first_frame": None,
        "last_frame": None,
        "frame_count": 0,
        "best_confidence": 0.0,
        "best_bbox_area": 0,
        "best_crop": None,
        "best_bbox": None,
    })

    progress(5)
    last_pct = 5

    for frame_idx, frame, total_frames in extract_frames(args.video, fps):
        # Run detection
        results = model(frame, imgsz=imgsz, conf=conf_threshold, verbose=False)

        if len(results) > 0 and results[0].boxes is not None:
            boxes = results[0].boxes
            xyxy = boxes.xyxy.cpu().numpy()
            confs = boxes.conf.cpu().numpy()
            class_ids = boxes.cls.cpu().numpy().astype(int)

            # Create supervision Detections
            detections = sv.Detections(
                xyxy=xyxy,
                confidence=confs,
                class_id=class_ids,
            )

            # Update tracker
            detections = tracker.update_with_detections(detections)

            # Process each tracked detection
            for i in range(len(detections)):
                track_id = int(detections.tracker_id[i])
                bbox = detections.xyxy[i]
                conf = float(detections.confidence[i])
                x1, y1, x2, y2 = bbox
                area = int((x2 - x1) * (y2 - y1))

                state = track_state[track_id]
                if state["first_frame"] is None:
                    state["first_frame"] = frame_idx
                state["last_frame"] = frame_idx
                state["frame_count"] += 1

                # Keep the best (largest + highest confidence) crop
                score = area * conf
                best_score = state["best_bbox_area"] * state["best_confidence"]
                if score > best_score:
                    state["best_confidence"] = conf
                    state["best_bbox_area"] = area
                    state["best_bbox"] = [float(x1), float(y1), float(x2), float(y2)]
                    # Only encode crop if it passes the area threshold
                    if area >= min_bbox_area:
                        state["best_crop"] = crop_and_encode(frame, bbox)

        # Report progress
        if total_frames > 0:
            pct = 5 + int((frame_idx / total_frames) * 90)
            if pct > last_pct + 4:
                progress(pct)
                last_pct = pct

    progress(95)

    # Output track summaries as JSONL
    for track_id, state in sorted(track_state.items()):
        record = {
            "track_id": track_id,
            "first_frame": state["first_frame"],
            "last_frame": state["last_frame"],
            "frame_count": state["frame_count"],
            "best_confidence": round(state["best_confidence"], 4),
            "best_bbox_area": state["best_bbox_area"],
            "bbox": state["best_bbox"],
            "crop_b64": state["best_crop"],  # None if below area threshold
        }
        print(json.dumps(record), flush=True)

    progress(100)


if __name__ == "__main__":
    main()

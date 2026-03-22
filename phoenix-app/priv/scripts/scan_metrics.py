#!/usr/bin/env python3
"""
Fast video metrics scanner.
Samples a few frames per video, runs YOLO detection, and writes
a .metrics.json index file with bbox count/size stats per video.

Usage:
  python scan_metrics.py /videos/fulhadoo /models/cfd-yolov12x-1.00.pt [--sample-frames 5] [--force]

Output: writes /videos/fulhadoo/.metrics.json
"""

import argparse
import cv2
import json
import os
import sys
import time
from pathlib import Path

VIDEO_EXTENSIONS = {".mp4", ".avi", ".mkv", ".mov", ".ts"}


def sample_frames(video_path, n_frames=5):
    """Extract n evenly-spaced frames from a video."""
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        return []

    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if total <= 0:
        cap.release()
        return []

    # Sample at evenly spaced positions (skip first/last 5%)
    start = int(total * 0.05)
    end = int(total * 0.95)
    if end <= start:
        start, end = 0, total - 1

    positions = [start + i * (end - start) // max(n_frames - 1, 1) for i in range(n_frames)]

    frames = []
    for pos in positions:
        cap.set(cv2.CAP_PROP_POS_FRAMES, pos)
        ret, frame = cap.read()
        if ret:
            frames.append(frame)

    cap.release()
    return frames


def scan_video(model, video_path, n_frames=5):
    """Run detection on sampled frames and return metrics."""
    frames = sample_frames(video_path, n_frames)
    if not frames:
        return None

    cap = cv2.VideoCapture(str(video_path))
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    fps = cap.get(cv2.CAP_PROP_FPS)
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    duration = total_frames / fps if fps > 0 else 0
    cap.release()

    all_areas = []
    total_detections = 0

    for frame in frames:
        results = model(frame, verbose=False, imgsz=640, conf=0.15)
        for r in results:
            boxes = r.boxes
            if boxes is not None and len(boxes) > 0:
                total_detections += len(boxes)
                for box in boxes.xyxy.cpu().numpy():
                    x1, y1, x2, y2 = box[:4]
                    area = int((x2 - x1) * (y2 - y1))
                    all_areas.append(area)

    n_sampled = len(frames)
    avg_detections = total_detections / n_sampled if n_sampled > 0 else 0

    return {
        "total_frames": total_frames,
        "fps": round(fps, 2),
        "duration_s": round(duration, 1),
        "resolution": f"{width}x{height}",
        "sampled_frames": n_sampled,
        "total_detections": total_detections,
        "avg_detections_per_frame": round(avg_detections, 1),
        "bbox_areas": {
            "count": len(all_areas),
            "min": min(all_areas) if all_areas else 0,
            "max": max(all_areas) if all_areas else 0,
            "mean": round(sum(all_areas) / len(all_areas)) if all_areas else 0,
        },
    }


def main():
    parser = argparse.ArgumentParser(description="Fast video metrics scanner")
    parser.add_argument("directory", help="Directory to scan")
    parser.add_argument("model_path", help="Path to YOLO model")
    parser.add_argument("--sample-frames", type=int, default=5, help="Frames to sample per video")
    parser.add_argument("--force", action="store_true", help="Rescan already-indexed videos")
    args = parser.parse_args()

    directory = Path(args.directory)
    if not directory.is_dir():
        print(f"Error: {directory} is not a directory", file=sys.stderr)
        sys.exit(1)

    index_path = directory / ".metrics.json"

    # Load existing index
    existing = {}
    if index_path.exists() and not args.force:
        with open(index_path) as f:
            existing = json.load(f)

    # Find videos to scan
    videos = sorted(
        p for p in directory.iterdir()
        if p.is_file() and p.suffix.lower() in VIDEO_EXTENSIONS
    )

    to_scan = [v for v in videos if v.name not in existing or args.force]

    if not to_scan:
        print(f"All {len(videos)} videos already indexed in {index_path}")
        return

    print(f"Scanning {len(to_scan)}/{len(videos)} videos in {directory}")

    # Load model once
    from ultralytics import YOLO
    model = YOLO(args.model_path)
    model.fuse()

    for i, video_path in enumerate(to_scan):
        t0 = time.time()
        metrics = scan_video(model, video_path, args.sample_frames)
        elapsed = time.time() - t0

        if metrics:
            existing[video_path.name] = metrics
            det = metrics["avg_detections_per_frame"]
            print(f"[{i+1}/{len(to_scan)}] {video_path.name}: {det:.1f} avg det/frame ({elapsed:.1f}s)")
        else:
            existing[video_path.name] = {"error": "could not read video"}
            print(f"[{i+1}/{len(to_scan)}] {video_path.name}: ERROR ({elapsed:.1f}s)")

        # Write incrementally so progress is saved
        with open(index_path, "w") as f:
            json.dump(existing, f, indent=2)

    print(f"Done. Index written to {index_path}")


if __name__ == "__main__":
    main()

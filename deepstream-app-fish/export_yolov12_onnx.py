#!/usr/bin/env python3
"""
Export YOLOv12 source checkpoint to ONNX for DeepStream/TensorRT.

Uses Ultralytics' built-in exporter. The resulting ONNX is consumed by the
nvdsinfer_custom_impl_Yolo plugin (see config_infer_primary_cfd_yolov12.txt).

Usage:
    python export_yolov12_onnx.py [cfd-yolov12x-1.00.pt]

After export, DeepStream will build the TensorRT engine on first launch and
cache it next to the .onnx file.
"""

import sys
from pathlib import Path


def main():
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("cfd-yolov12x-1.00.pt")

    if not src.exists():
        print(f"error: {src} not found. Run `mix models.fetch` first.", file=sys.stderr)
        sys.exit(1)

    try:
        from ultralytics import YOLO
    except ImportError:
        print("error: ultralytics not installed. `pip install ultralytics`", file=sys.stderr)
        sys.exit(1)

    print(f"loading {src}")
    model = YOLO(str(src))

    print("exporting to ONNX (opset=12, simplify=True)")
    out = model.export(format="onnx", opset=12, simplify=True, dynamic=False)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()

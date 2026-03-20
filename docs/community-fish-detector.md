# Community Fish Detector (CFD)

Source: https://github.com/filippovarini/community-fish-detector

## Overview

Pretrained YOLOv12x model for single-class fish detection, trained on the
[Community Fish Detection Dataset](https://lila.science/datasets/community-fish-detection-dataset)
— a large-scale dataset unifying **>1.9M images** and **>935K fish bounding boxes**
from 17 open datasets spanning freshwater, marine, and laboratory environments.

License: **AGPL**

## Model Details

| Field             | Value                   |
|-------------------|-------------------------|
| Architecture      | YOLOv12x (ultralytics)  |
| Weights file      | `cfd-yolov12x-1.00.pt`  |
| File size         | ~119 MB                 |
| Input size        | **1024px** (critical)   |
| Classes           | 1 (fish)                |
| Framework         | ultralytics (`pip install ultralytics`) |
| Training details  | 100 epochs, batch 8, img 1024, best = epoch 88 |

Download URL:
https://github.com/filippovarini/community-fish-detector/releases/download/cfd-1.00-yolov12x/cfd-yolov12x-1.00.pt

## Quick Usage

```python
from ultralytics import YOLO

model = YOLO("path/to/cfd-yolov12x-1.00.pt")
results = model.predict(source="path/to/images_or_videos", imgsz=1024)
results[0].show()
```

**Warning:** Always set `imgsz=1024`. The YOLO default of 640 will degrade performance.

## Training Dataset Composition

The Community Fish Detection Dataset aggregates 17 sources into a unified
COCO-JSON format with a single "fish" category:

- **Marine/Brackish:** Brackish Dataset (~14.7K frames), Coralscapes (2K images),
  Marine Detect, FathomNet, Project Natick (1K images), Puget Sound Nearshore Fish
- **Freshwater:** Tropical freshwater (44K images), MIT Sea Grant River Herring (~262K frames),
  Salmon Computer Vision (532K frames, 15 species)
- **Laboratory:** AAU Zebrafish (~2.2K images)
- **Other:** FishCLEF-2015, DeepFish, Deep Vision Fish, F4K, Roboflow Fish, FishTrack23, TORSI

Data is distributed via GCP, AWS, and Azure. Mixed licenses (CC-BY, CC0, CC-BY-NC,
Apache 2.0, MIT, CDLA-permissive 1.0).

## Key Differences from Current YOLO-Fish Setup

| Aspect           | Current (YOLO-Fish/darknet)      | CFD (YOLOv12x/ultralytics)       |
|------------------|----------------------------------|----------------------------------|
| Framework        | Darknet (C)                      | Ultralytics/PyTorch              |
| Architecture     | YOLOv3 custom                    | YOLOv12x                         |
| Input size       | 416/608                          | 1024                             |
| Training data    | DeepFish + OzFish                | 17 datasets, >1.9M images        |
| Weights format   | `.weights` (Darknet)             | `.pt` (PyTorch)                  |
| DeepStream       | Native via custom parser + .cfg  | Requires ONNX export first       |
| Classes          | 1 (Fish)                         | 1 (fish)                         |

## ONNX Export for DeepStream Integration

The ultralytics `.pt` format is not directly usable by DeepStream's nvinfer plugin.
To integrate, the model must be exported to ONNX:

```python
from ultralytics import YOLO

model = YOLO("cfd-yolov12x-1.00.pt")
model.export(format="onnx", imgsz=1024, opset=12, simplify=True)
# produces cfd-yolov12x-1.00.onnx
```

DeepStream 6.x+ can then load the ONNX file via nvinfer with `onnx-file=` property,
and TensorRT will build an optimized engine on first run.

## HuggingFace Demo

Interactive demo: https://huggingface.co/spaces/FathomNet/community-fish-detector

## Contact

Filippo Varini — fppvrn@gmail.com

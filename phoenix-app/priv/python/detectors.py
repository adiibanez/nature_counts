"""
Pluggable fish detector backends.

Provides a unified interface for YOLO (ultralytics) and RF-DETR (rfdetr) models.
Both return (xyxy, confidence, class_ids) as numpy arrays in absolute pixel coords.

Usage:
    from detectors import create_detector
    detector = create_detector("/path/to/model.pt")  # or .pth for RF-DETR
    xyxy, confs, class_ids = detector.predict(frame_bgr, imgsz=640, conf=0.15)
"""

import numpy as np
from PIL import Image


class BaseDetector:
    """Common interface for fish detectors."""

    def predict(self, frame_bgr, imgsz=640, conf=0.15):
        """Run detection on a BGR numpy frame.

        Returns:
            xyxy: ndarray (N, 4) absolute pixel coords
            confidence: ndarray (N,)
            class_ids: ndarray (N,) int
        """
        raise NotImplementedError


class YOLODetector(BaseDetector):
    def __init__(self, model_path, device="cuda:0"):
        from ultralytics import YOLO
        self.model = YOLO(model_path, task="detect")
        self.model.to(device)

    def predict(self, frame_bgr, imgsz=640, conf=0.15):
        results = self.model(frame_bgr, imgsz=imgsz, conf=conf, verbose=False)
        if len(results) > 0 and results[0].boxes is not None and len(results[0].boxes) > 0:
            boxes = results[0].boxes
            xyxy = boxes.xyxy.cpu().numpy()
            confs = boxes.conf.cpu().numpy()
            class_ids = boxes.cls.cpu().numpy().astype(int)
            return xyxy, confs, class_ids
        return np.empty((0, 4)), np.empty(0), np.empty(0, dtype=int)


class RFDETRDetector(BaseDetector):
    def __init__(self, model_path, device="cuda:0"):
        from rfdetr import RFDETRNano
        self.model = RFDETRNano(pretrain_weights=model_path, resolution=640)

    def predict(self, frame_bgr, imgsz=640, conf=0.15):
        # RF-DETR expects PIL RGB images
        frame_rgb = frame_bgr[:, :, ::-1]  # BGR -> RGB
        pil_image = Image.fromarray(frame_rgb)

        detections = self.model.predict(pil_image, threshold=conf)

        if detections is not None and len(detections) > 0:
            xyxy = detections.xyxy
            confs = detections.confidence
            class_ids = (
                detections.class_id
                if detections.class_id is not None
                else np.zeros(len(confs), dtype=int)
            )
            return xyxy, confs, class_ids
        return np.empty((0, 4)), np.empty(0), np.empty(0, dtype=int)


def create_detector(model_path, device="cuda:0"):
    """Factory: pick detector based on file extension.

    .pth files -> RF-DETR
    .pt / .onnx files -> YOLO (ultralytics)
    """
    if model_path.endswith(".pth"):
        return RFDETRDetector(model_path, device)
    else:
        return YOLODetector(model_path, device)

"""Local COCO object detection using RF-DETR, without a network service."""

from __future__ import annotations

import os
from pathlib import Path

# Some PyTorch operators do not have an MPS implementation. Set this before
# importing torch so that those operators may execute on the CPU instead.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import numpy as np
import torch
from rfdetr import RFDETRMedium, RFDETRNano

ROOT = Path(__file__).resolve().parent.parent


class Detector:
    """Predict COCO classes. Bounding boxes are in source-image pixels."""

    def __init__(self, threshold: float = 0.35, model_size: str = "medium"):
        if not 0 <= threshold <= 1:
            raise ValueError("threshold must be between 0 and 1")
        if model_size not in ("medium", "nano"):
            raise ValueError("model_size must be medium or nano")
        weights = ROOT / "model" / f"rf-detr-{model_size}.pth"
        if not weights.is_file():
            raise FileNotFoundError(f"Object detection weights not found: {weights}")
        self.threshold = threshold
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"
        cls = RFDETRMedium if model_size == "medium" else RFDETRNano
        self.model = cls(pretrain_weights=str(weights), device=self.device)
        # Export-mode graph avoids training-only paths; tracing is deliberately
        # disabled to avoid slow initialization and unsupported MPS operators.
        self.model.optimize_for_inference(compile=False)
        self.info = {
            "model": f"RF-DETR {model_size.capitalize()} COCO",
            "device": self.device,
            "classes": "COCO",
            "threshold": self.threshold,
            "mps_cpu_fallback": self.device == "mps",
        }

    def detect(self, image: np.ndarray) -> list[dict]:
        if not isinstance(image, np.ndarray) or image.ndim != 3 or image.shape[2] != 3:
            raise ValueError("image must be an RGB numpy array with shape H x W x 3")
        if image.dtype != np.uint8:
            raise ValueError("image must contain uint8 RGB pixels")
        height, width = image.shape[:2]
        predictions = self.model.predict(np.ascontiguousarray(image), threshold=self.threshold)
        names = self.model.class_names
        detections = []
        for box, score, class_id in zip(predictions.xyxy, predictions.confidence, predictions.class_id):
            x1, y1, x2, y2 = [float(value) for value in box]
            x1, x2 = max(0.0, min(width, x1)), max(0.0, min(width, x2))
            y1, y2 = max(0.0, min(height, y1)), max(0.0, min(height, y2))
            if x2 <= x1 or y2 <= y1 or not np.isfinite([x1, y1, x2, y2, score]).all():
                continue
            detections.append({
                "label": names.get(int(class_id), f"class {int(class_id)}"),
                "confidence": float(score),
                "box": [x1, y1, x2, y2],
            })
        return detections

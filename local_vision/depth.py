"""Local monocular depth estimation, in model-estimated metres.

This indoor-trained model estimates depth from appearance, not a direct range
measurement. It can be substantially wrong outside its training domain.
"""
from pathlib import Path
import os

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image
from transformers import AutoImageProcessor, AutoModelForDepthEstimation


class DepthEstimator:
    MODEL_PATH = Path(__file__).resolve().parents[1] / "model" / "local-depth"

    def __init__(self):
        if not (self.MODEL_PATH / "model.safetensors").is_file():
            raise FileNotFoundError(f"Depth model missing: {self.MODEL_PATH}")
        requested = os.getenv("PELAGIVEX_DEPTH_DEVICE", "auto")
        if requested not in {"auto", "cpu", "mps"}:
            raise ValueError("PELAGIVEX_DEPTH_DEVICE must be auto, cpu or mps")
        available = torch.backends.mps.is_available()
        if requested == "mps" and not available:
            raise RuntimeError("MPS was requested but is unavailable")
        self.device = torch.device("mps" if available and requested != "cpu" else "cpu")
        self.processor = AutoImageProcessor.from_pretrained(self.MODEL_PATH, local_files_only=True, use_fast=False)
        self.model = AutoModelForDepthEstimation.from_pretrained(self.MODEL_PATH, local_files_only=True).to(self.device).eval()

    @property
    def info(self):
        return {
            "name": "Depth Anything V2 Metric Indoor Base",
            "device": str(self.device),
            "unit": "estimated meters",
            "domain": "indoor",
            "license": "CC-BY-NC-4.0",
            "source": "https://huggingface.co/depth-anything/Depth-Anything-V2-Metric-Indoor-Base-hf",
        }

    @torch.inference_mode()
    def estimate(self, image):
        """Return an HxW float32 model-estimated depth map aligned to RGB input."""
        if not isinstance(image, np.ndarray) or image.ndim != 3 or image.shape[2] != 3 or image.dtype != np.uint8:
            raise ValueError("Expected an HxWx3 RGB uint8 numpy image")
        height, width = image.shape[:2]
        if not height or not width:
            raise ValueError("Image must not be empty")
        pixels = self.processor(images=Image.fromarray(image), return_tensors="pt").pixel_values.to(self.device)
        depth = self.model(pixel_values=pixels).predicted_depth
        depth = F.interpolate(depth.unsqueeze(1), size=(height, width), mode="bicubic", align_corners=False)[0, 0]
        return depth.to(device="cpu", dtype=torch.float32).numpy()

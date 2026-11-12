"""Optional on-device Depth Pro candidate, returning model-estimated metres.

The estimates are not physical measurements. This adapter uses the checkpoint's
predicted focal length because ordinary browser camera frames do not include a
calibrated focal length. Model weights are used under Apple's AMLR terms.
"""
from pathlib import Path
import os

import numpy as np
import torch
from PIL import Image
from transformers import DepthProForDepthEstimation, DepthProImageProcessorFast


class DepthProEstimator:
    MODEL_PATH = Path(__file__).resolve().parents[1] / 'model' / 'local-depth-pro'

    def __init__(self):
        if not (self.MODEL_PATH / 'model.safetensors').is_file():
            raise FileNotFoundError(f'Depth Pro model missing: {self.MODEL_PATH}')
        requested = os.getenv('PELAGIVEX_DEPTH_PRO_DEVICE', 'auto')
        if requested not in {'auto', 'cpu', 'mps'}:
            raise ValueError('PELAGIVEX_DEPTH_PRO_DEVICE must be auto, cpu or mps')
        available = torch.backends.mps.is_available()
        if requested == 'mps' and not available:
            raise RuntimeError('MPS was requested but is unavailable')
        self.device = torch.device('mps' if available and requested != 'cpu' else 'cpu')
        self.processor = DepthProImageProcessorFast.from_pretrained(self.MODEL_PATH, local_files_only=True)
        # Apple publishes this checkpoint in float16; preserve it on MPS.
        dtype = torch.float16 if self.device.type == 'mps' else torch.float32
        self.model = DepthProForDepthEstimation.from_pretrained(
            self.MODEL_PATH, local_files_only=True, torch_dtype=dtype).to(self.device).eval()
        self.dtype = dtype
        self.last_focal_length = None
        self.last_fov = None

    @property
    def info(self):
        return {'name': 'Apple Depth Pro', 'device': str(self.device),
                'unit': 'estimated meters', 'focal_length': 'model-estimated',
                'license': 'apple-amlr',
                'source': 'https://huggingface.co/apple/DepthPro-hf'}

    @torch.inference_mode()
    def estimate(self, image):
        if not isinstance(image, np.ndarray) or image.dtype != np.uint8 or image.ndim != 3 or image.shape[2] != 3:
            raise ValueError('Expected an HxWx3 RGB uint8 numpy image')
        h, w = image.shape[:2]
        if not h or not w:
            raise ValueError('Image must not be empty')
        inputs = self.processor(images=Image.fromarray(image), return_tensors='pt')
        inputs = {k: v.to(device=self.device, dtype=self.dtype if v.is_floating_point() else v.dtype)
                  for k, v in inputs.items()}
        output = self.model(**inputs)
        # This performs essential focal-length correction and inverse-depth conversion.
        result = self.processor.post_process_depth_estimation(output, target_sizes=[(h, w)])[0]
        self.last_focal_length = float(result['focal_length'].float().cpu()) if result['focal_length'] is not None else None
        self.last_fov = float(result['field_of_view'].float().cpu()) if result['field_of_view'] is not None else None
        return result['predicted_depth'].to(device='cpu', dtype=torch.float32).numpy()

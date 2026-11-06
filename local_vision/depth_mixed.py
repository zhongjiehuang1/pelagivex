"""Experimental MPS mixed-precision candidate for same-frame depth comparisons.

Weights remain FP32; PyTorch autocast chooses precision per operation. This is
not the same as converting every weight to FP16, which can severely distort
metric depth while still producing finite output.
"""
import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image

from depth import DepthEstimator


class DepthMixedEstimator(DepthEstimator):
    def __init__(self, base=None):
        if base is None:
            super().__init__()
        else:
            # Share the unchanged FP32 weights and processor. Inference must
            # be serialized when this instance and base share the model.
            self.model, self.processor, self.device = base.model, base.processor, base.device
        self.use_mixed = self.device.type == 'mps'

    @property
    def info(self):
        return {**super().info, 'precision': 'MPS autocast FP16/FP32' if self.use_mixed else 'FP32',
                'note': 'Experimental mixed precision; compare with FP32 on representative scenes.'}

    @torch.inference_mode()
    def estimate(self, image):
        if not self.use_mixed:
            return super().estimate(image)
        if not isinstance(image, np.ndarray) or image.ndim != 3 or image.shape[2] != 3 or image.dtype != np.uint8:
            raise ValueError('Expected an HxWx3 RGB uint8 numpy image')
        height, width = image.shape[:2]
        if not height or not width:
            raise ValueError('Image must not be empty')
        try:
            pixels = self.processor(images=Image.fromarray(image), return_tensors='pt').pixel_values.to(self.device)
            with torch.autocast(device_type='mps', dtype=torch.float16):
                depth = self.model(pixel_values=pixels).predicted_depth
            # Interpolate in FP32, matching the validated comparison path.
            depth = F.interpolate(depth.unsqueeze(1).float(), size=(height, width),
                                  mode='bicubic', align_corners=False)[0, 0]
            # The returned array must already be copied to CPU; validate it
            # there to avoid an extra GPU reduction and synchronization.
            result = depth.to(device='cpu', dtype=torch.float32).numpy()
            if not np.isfinite(result).all():
                raise FloatingPointError('Non-finite mixed-precision depth')
            return result
        except (RuntimeError, FloatingPointError) as exc:
            print(f'Depth mixed precision unavailable; retrying in FP32: {exc}', flush=True)
            self.use_mixed = False
            return super().estimate(image)

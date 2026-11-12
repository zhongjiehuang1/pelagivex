"""Local, text-prompted OWLv2 detector; independent of the RF-DETR service."""
from __future__ import annotations

import os
from pathlib import Path

os.environ.setdefault('PYTORCH_ENABLE_MPS_FALLBACK', '1')

import numpy as np
import torch
from PIL import Image
from torchvision.ops import nms
from transformers import Owlv2ForObjectDetection, Owlv2Processor

ROOT = Path(__file__).resolve().parent.parent


class OwlDetector:
    """Open-vocabulary detection; text labels are hypotheses, not guarantees."""

    def __init__(self, threshold: float = 0.2, nms_iou: float = 0.5):
        if not 0 <= threshold <= 1 or not 0 <= nms_iou <= 1:
            raise ValueError('threshold and nms_iou must be between 0 and 1')
        self.path = ROOT / '.cache' / 'owlv2'
        if not (self.path / 'model.safetensors').is_file():
            raise FileNotFoundError(f'OWLv2 weights missing: {self.path}')
        self.threshold = threshold
        self.nms_iou = nms_iou
        self.device = torch.device('mps' if torch.backends.mps.is_available() else 'cpu')
        # Transformers' torchvision-backed processor preserves the checkpoint's
        # 960px input while reducing Python/PIL resize and normalization cost.
        self.processor = Owlv2Processor.from_pretrained(self.path, local_files_only=True, use_fast=True)
        self._slow_processor = None
        self._fast_processor = self.processor.image_processor.__class__.__name__.endswith('Fast')
        self.model = Owlv2ForObjectDetection.from_pretrained(self.path, local_files_only=True).to(self.device).eval()
        # Keep FP32 on CPU. FP16 reduces MPS compute and memory; retry FP32 on
        # unsupported operations or non-finite network predictions.
        self.use_fp16 = self.device.type == 'mps'
        if self.use_fp16:
            try:
                self.model.half()
            except RuntimeError:
                self.model.float()
                self.use_fp16 = False
        self.info = {'model': 'Google OWLv2 Base patch16 ensemble', 'device': str(self.device),
                     'license': 'Apache-2.0', 'threshold': self.threshold, 'nms_iou': self.nms_iou,
                     'precision': 'float16' if self.use_fp16 else 'float32',
                     'image_processor': self.processor.image_processor.__class__.__name__,
                     'source': 'https://huggingface.co/google/owlv2-base-patch16-ensemble',
                     'note': 'Open-vocabulary scores depend on prompts and are not calibrated probabilities.'}

    @torch.inference_mode()
    def detect(self, image: np.ndarray, prompts: list[str]) -> list[dict]:
        if not isinstance(image, np.ndarray) or image.ndim != 3 or image.shape[2] != 3 or image.dtype != np.uint8:
            raise ValueError('image must be an H x W x 3 RGB uint8 array')
        if not isinstance(prompts, list) or not 1 <= len(prompts) <= 32:
            raise ValueError('provide 1 to 32 text prompts')
        if any(not isinstance(p, str) or not p.strip() or len(p) > 128 for p in prompts):
            raise ValueError('each prompt must be a nonempty string up to 128 characters')
        height, width = image.shape[:2]
        if min(height, width) == 0:
            raise ValueError('image is empty')
        processor = self.processor
        # The fast and reference resize kernels can diverge at the edges when
        # enlarging small images. Keep the original processor for that case.
        if getattr(self, '_fast_processor', False) and max(height, width) < 960:
            if self._slow_processor is None:
                self._slow_processor = Owlv2Processor.from_pretrained(self.path, local_files_only=True, use_fast=False)
            processor = self._slow_processor
        inputs = processor(text=[prompts], images=Image.fromarray(image), return_tensors='pt').to(self.device)
        try:
            if self.use_fp16:
                inputs['pixel_values'] = inputs['pixel_values'].half()
            outputs = self.model(**inputs)
            if self.use_fp16 and (not torch.isfinite(outputs.logits).all().item() or
                                  not torch.isfinite(outputs.pred_boxes).all().item()):
                raise FloatingPointError('Non-finite OWLv2 FP16 outputs')
        except (RuntimeError, FloatingPointError) as exc:
            if not self.use_fp16:
                raise
            print(f'OWLv2 FP16 unavailable; retrying in FP32: {exc}', flush=True)
            self.model.float()
            self.use_fp16 = False
            self.info['precision'] = 'float32 (fallback)'
            inputs['pixel_values'] = inputs['pixel_values'].float()
            outputs = self.model(**inputs)
        # Processor uses the square padded size when mapping coordinates back.
        result = processor.post_process_grounded_object_detection(
            outputs, threshold=self.threshold, target_sizes=torch.tensor([[height, width]], device=self.device),
            text_labels=[prompts])[0]
        # torchvision CPU NMS does not implement half precision.
        boxes = result['boxes'].to(device='cpu', dtype=torch.float32)
        scores = result['scores'].to(device='cpu', dtype=torch.float32)
        labels = result['labels'].to('cpu')
        if not len(scores):
            return []
        boxes[:, (0, 2)] = boxes[:, (0, 2)].clamp(0, width)
        boxes[:, (1, 3)] = boxes[:, (1, 3)].clamp(0, height)
        valid = torch.isfinite(boxes).all(dim=1) & torch.isfinite(scores) & (boxes[:, 2] > boxes[:, 0]) & (boxes[:, 3] > boxes[:, 1])
        boxes, scores, labels = boxes[valid], scores[valid], labels[valid]
        if not len(scores):
            return []
        # Suppress overlapping responses to synonyms across all prompted labels.
        keep = nms(boxes, scores, self.nms_iou)[:25]
        return [{'label': prompts[int(labels[i])], 'confidence': float(scores[i]),
                 'box': [float(v) for v in boxes[i]]} for i in keep]

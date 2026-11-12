"""Optional OWLv2 Large, local text-guided detection for detailed comparisons."""
from pathlib import Path
import numpy as np
import torch
from transformers import Owlv2ForObjectDetection, Owlv2Processor
from owl_detector import OwlDetector


class OwlLargeDetector(OwlDetector):
    """Same output interface as OwlDetector; separate weights and inference state."""
    def __init__(self, threshold: float = 0.2, nms_iou: float = 0.5):
        if not 0 <= threshold <= 1 or not 0 <= nms_iou <= 1:
            raise ValueError('threshold and nms_iou must be between 0 and 1')
        self.path = Path(__file__).resolve().parent.parent / '.cache' / 'owlv2-large'
        if not (self.path / 'model.safetensors').is_file():
            raise FileNotFoundError(f'OWLv2 Large weights missing: {self.path}')
        self.threshold, self.nms_iou = threshold, nms_iou
        self.device = torch.device('mps' if torch.backends.mps.is_available() else 'cpu')
        self.processor = Owlv2Processor.from_pretrained(self.path, local_files_only=True, use_fast=True)
        self._slow_processor = None
        self._fast_processor = self.processor.image_processor.__class__.__name__.endswith('Fast')
        self.model = Owlv2ForObjectDetection.from_pretrained(self.path, local_files_only=True).to(self.device).eval()
        self.use_fp16 = self.device.type == 'mps'
        if self.use_fp16:
            try:
                self.model.half()
            except RuntimeError:
                self.model.float()
                self.use_fp16 = False
        self.info = {'model': 'Google OWLv2 Large patch14 ensemble', 'device': str(self.device),
                     'license': 'Apache-2.0', 'threshold': self.threshold, 'nms_iou': self.nms_iou,
                     'precision': 'float16' if self.use_fp16 else 'float32',
                     'image_processor': self.processor.image_processor.__class__.__name__,
                     'source': 'https://huggingface.co/google/owlv2-large-patch14-ensemble',
                     'note': 'Text-prompted estimates; confidence is not a calibrated probability.'}

    def detect(self, image, prompts):
        # The Large checkpoint uses 1008-pixel input; for upsampling, preserve
        # the reference processor rather than assuming Base's 960-pixel limit.
        if isinstance(image, np.ndarray) and image.ndim == 3 and getattr(self, '_fast_processor', False) and max(image.shape[:2]) < 1008:
            if self._slow_processor is None:
                self._slow_processor = Owlv2Processor.from_pretrained(self.path, local_files_only=True, use_fast=False)
            original_processor, original_flag = self.processor, self._fast_processor
            self.processor, self._fast_processor = self._slow_processor, False
            try:
                return super().detect(image, prompts)
            finally:
                self.processor, self._fast_processor = original_processor, original_flag
        return super().detect(image, prompts)

"""Exercise the FP16 error fallback without loading model weights."""
import sys
import unittest
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from owl_detector import OwlDetector


class Inputs(dict):
    def to(self, device):
        return self


class Processor:
    def __call__(self, **kwargs):
        return Inputs(pixel_values=torch.ones((1, 3, 2, 2)), input_ids=torch.ones((1, 1), dtype=torch.long))

    def post_process_grounded_object_detection(self, outputs, **kwargs):
        return [{'boxes': torch.tensor([[0., 0., 2., 2.]], dtype=outputs.logits.dtype),
                 'scores': torch.tensor([.8], dtype=outputs.logits.dtype),
                 'labels': torch.tensor([0])}]


class Model:
    def __init__(self, failure):
        self.calls = []
        self.failure = failure
        self.float_called = False

    def float(self):
        self.float_called = True
        return self

    def __call__(self, pixel_values, **kwargs):
        self.calls.append(pixel_values.dtype)
        if len(self.calls) == 1 and self.failure == 'operation':
            raise RuntimeError('unsupported half precision operation')
        value = float('nan') if len(self.calls) == 1 and self.failure == 'nonfinite' else 1.0
        return type('Output', (), {'logits': torch.tensor([value]), 'pred_boxes': torch.tensor([1.0])})()


class OwlPrecisionTests(unittest.TestCase):
    def check_fallback(self, failure):
        detector = OwlDetector.__new__(OwlDetector)
        detector.processor = Processor()
        detector.model = Model(failure)
        detector.use_fp16 = True
        detector.device = torch.device('cpu')
        detector.info = {}
        detector.threshold = .2
        detector.nms_iou = .5
        output = detector.detect(np.zeros((2, 2, 3), np.uint8), ['box'])
        self.assertEqual(detector.model.calls, [torch.float16, torch.float32])
        self.assertTrue(detector.model.float_called)
        self.assertEqual(detector.info['precision'], 'float32 (fallback)')
        self.assertFalse(detector.use_fp16)
        self.assertEqual(output[0]['label'], 'box')

    def test_fallback_when_half_operation_fails(self):
        self.check_fallback('operation')

    def test_fallback_when_half_output_nonfinite(self):
        self.check_fallback('nonfinite')


if __name__ == '__main__':
    unittest.main()

"""Validate the mixed-precision candidate's FP32 fallback and contract."""
import sys
import unittest
from contextlib import nullcontext
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from depth_mixed import DepthMixedEstimator


class Processor:
    def __call__(self, **kwargs):
        return SimpleNamespace(pixel_values=torch.ones((1, 3, 2, 2)))


class Model:
    def __init__(self, failure):
        self.failure = failure
        self.calls = 0

    def __call__(self, **kwargs):
        self.calls += 1
        if self.calls == 1 and self.failure == 'operation':
            raise RuntimeError('unsupported operation')
        value = float('nan') if self.calls == 1 and self.failure == 'nonfinite' else 2.0
        return SimpleNamespace(predicted_depth=torch.full((1, 2, 2), value))


class MixedDepthTests(unittest.TestCase):
    def check_case(self, failure):
        candidate = DepthMixedEstimator.__new__(DepthMixedEstimator)
        candidate.device = torch.device('cpu')
        candidate.processor = Processor()
        candidate.model = Model(failure)
        candidate.use_mixed = True
        with patch('depth_mixed.torch.autocast', return_value=nullcontext()):
            result = candidate.estimate(np.zeros((4, 5, 3), dtype=np.uint8))
        self.assertEqual(result.shape, (4, 5))
        np.testing.assert_allclose(result, 2.0, rtol=1e-6)
        self.assertFalse(candidate.use_mixed)
        self.assertEqual(candidate.model.calls, 2)

    def test_wrap_existing_base_without_copy(self):
        base = SimpleNamespace(device=torch.device('cpu'), processor=Processor(), model=Model(None))
        candidate = DepthMixedEstimator(base)
        self.assertIs(candidate.model, base.model)
        self.assertIs(candidate.processor, base.processor)
        self.assertFalse(candidate.use_mixed)

    def test_fallback_from_operation_error(self):
        self.check_case('operation')

    def test_fallback_from_nonfinite_output(self):
        self.check_case('nonfinite')


if __name__ == '__main__':
    unittest.main()

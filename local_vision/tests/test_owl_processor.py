"""Check the fast processor keeps OWLv2 preprocessing aligned with the checkpoint."""
import unittest
from pathlib import Path

import numpy as np
from PIL import Image
from transformers import Owlv2Processor

MODEL = Path(__file__).resolve().parents[2] / '.cache' / 'owlv2'


@unittest.skipUnless((MODEL / 'preprocessor_config.json').is_file(), 'OWLv2 processor files unavailable')
class OwlProcessorParityTest(unittest.TestCase):
    def test_fast_matches_reference_on_landscape_and_portrait(self):
        fast = Owlv2Processor.from_pretrained(MODEL, local_files_only=True, use_fast=True)
        slow = Owlv2Processor.from_pretrained(MODEL, local_files_only=True, use_fast=False)
        rng = np.random.default_rng(42)
        for height, width in ((720, 1280), (1280, 720)):
            with self.subTest(height=height, width=width):
                rgb = rng.integers(0, 256, (height, width, 3), dtype=np.uint8)
                image = Image.fromarray(rgb)
                reference = slow(text=[['tissue box']], images=image, return_tensors='pt')
                result = fast(text=[['tissue box']], images=image, return_tensors='pt')
                self.assertEqual(reference['pixel_values'].shape, result['pixel_values'].shape)
                np.testing.assert_allclose(result['pixel_values'].numpy(), reference['pixel_values'].numpy(), rtol=0, atol=5e-4)
                np.testing.assert_array_equal(result['input_ids'].numpy(), reference['input_ids'].numpy())


if __name__ == '__main__':
    unittest.main()

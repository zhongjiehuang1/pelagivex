import unittest
try:
    import numpy as np
    from mask_depth import instance_depth
except ImportError:
    np = None

@unittest.skipIf(np is None, "NumPy and OpenCV are required")
class MaskDepthTests(unittest.TestCase):
    def test_foreground_mask_excludes_box_background(self):
        depth = np.full((20, 20), 9, dtype=np.float32)
        depth[4:16, 2:9] = 2
        proto = np.full((1, 20, 20), -1, dtype=np.float32)
        proto[0, 4:16, 2:9] = 1
        self.assertAlmostEqual(instance_depth(depth, proto, [1], [0, 0, 1, 1], 20), 2)
    def test_empty_mask_and_bad_values_have_no_estimate(self):
        depth = np.ones((10, 10), dtype=np.float32)
        proto = -np.ones((1, 10, 10), dtype=np.float32)
        self.assertIsNone(instance_depth(depth, proto, [1], [0, 0, 1, 1], 10))
        self.assertIsNone(instance_depth(depth, proto, [float('nan')], [0, 0, 1, 1], 10))
    def test_letterbox_excludes_padding(self):
        depth = np.full((10, 20), 3, dtype=np.float32)
        proto = np.ones((1, 20, 20), dtype=np.float32)
        self.assertAlmostEqual(instance_depth(depth, proto, [1], [0, 0, 1, 1], 20), 3)

if __name__ == '__main__': unittest.main()

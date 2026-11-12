import base64
import io
import unittest
import json

from segmentation_refiner import (
    SegmentationRefiner, choose_masks, compose_instance_map, encode_instance_map,
    instance_priorities, merge_priority_masks, output_size,
)
from open_vocab_worker import parse_refinement_request, request_object

try:
    import numpy as np
    from PIL import Image
except ImportError:
    np = None


class SegmentationDimensionsTests(unittest.TestCase):
    def test_aspect_ratio_preserved_and_smaller_images_not_enlarged(self):
        self.assertEqual(output_size(1920, 1080), (1024, 576))
        self.assertEqual(output_size(480, 640), (480, 640))
        self.assertEqual(output_size(1080, 1920), (576, 1024))
        with self.assertRaises(ValueError):
            output_size(0, 20)

    def test_refinement_protocol_preserves_input_order_and_accepts_one_hundred(self):
        entries = [{"label": f"object {index}", "confidence": (100-index)/100,
                    "box": [0, 0, 0.5, 0.5]} for index in range(100)]
        entries.reverse()
        line = json.dumps({"image": base64.b64encode(b"jpeg").decode(),
                           "refineDetections": entries}).encode()
        data, result = parse_refinement_request(line)
        self.assertEqual(data, b"jpeg")
        self.assertEqual(result, entries)
        self.assertTrue(request_object(line).get("refineOutlines", True))

    def test_refinement_protocol_rejects_empty_invalid_boxes_and_non_boolean_flag(self):
        base = {"image": base64.b64encode(b"jpeg").decode(),
                "refineDetections": [{"label": "object", "confidence": 0.5, "box": [0, 0, 1, 1]}]}
        for entries in ([], base["refineDetections"] * 101, [{"label": "object", "confidence": True, "box": [0, 0, 1, 1]}],
                        [{"label": "object", "confidence": 0.5, "box": [0, 0, 0, 1]}]):
            with self.subTest(entries=len(entries)), self.assertRaises(ValueError):
                parse_refinement_request(json.dumps({**base, "refineDetections": entries}).encode())
        with self.assertRaises(ValueError):
            request_object(json.dumps({**base, "refineOutlines": "true"}).encode())


@unittest.skipIf(np is None, "NumPy and Pillow required")
class SegmentationMapTests(unittest.TestCase):
    def test_chunked_integer_composition_matches_cpu_for_twenty_five_instances(self):
        try:
            import torch
        except ImportError:
            self.skipTest("PyTorch unavailable")
        random = np.random.default_rng(51)
        masks = random.random((25, 37, 53)) > 0.8
        # Include a float64 distinction that a float32 confidence-map would lose.
        detections = [{"confidence": 0.5 if index % 3 else 0.50000000001} for index in range(25)]
        expected = compose_instance_map(masks, detections, 53, 37)
        priorities, lookup = instance_priorities(detections)
        for chunk_size in (1, 4, 8, 25):
            current = torch.zeros((37, 53), dtype=torch.int32)
            for first in range(0, 25, chunk_size):
                current = merge_priority_masks(current, torch.from_numpy(masks[first:first+chunk_size]),
                                               priorities[first:first+chunk_size])
            actual = lookup[current.to(torch.uint8).numpy()]
            np.testing.assert_array_equal(actual, expected)

    def test_device_selection_matches_reference_without_loading_model_weights(self):
        try:
            import torch
        except ImportError:
            self.skipTest("PyTorch unavailable")
        from types import SimpleNamespace
        low = torch.tensor([
            [[[1., -1.], [1., -1.]], [[-2., 2.], [-2., 2.]], [[2., 2.], [-2., -2.]]],
            [[[1., 1.], [1., 1.]], [[0., 0.], [0., 0.]], [[-1., -1.], [-1., -1.]]],
        ])
        quality = torch.tensor([[0.2, 0.9, 0.3], [float("nan")] * 3])
        class PromptEncoder:
            def __call__(self, *, points, boxes, masks):
                return torch.zeros((2, 2, 2)), torch.zeros((2, 2, 2, 2))
            def get_dense_pe(self):
                return torch.zeros((1, 2, 2, 2))
        postprocess = lambda masks, size: torch.nn.functional.interpolate(
            masks, size, mode="bilinear", align_corners=False)
        predictor = SimpleNamespace(
            _prep_prompts=lambda a, b, boxes, c, d: (None, None, None, torch.tensor(boxes)),
            _features={"high_res_feats": [torch.zeros((1, 2, 2, 2))],
                       "image_embed": torch.zeros((1, 2, 2, 2))},
            _orig_hw=[(4, 5)],
            _transforms=SimpleNamespace(postprocess_masks=postprocess),
            model=SimpleNamespace(sam_prompt_encoder=PromptEncoder(),
                                  sam_mask_decoder=lambda **kwargs: (low, quality, None, None)),
        )
        refiner = object.__new__(SegmentationRefiner)
        refiner.predictor = predictor
        masks, scores = refiner._predict_selected(np.array([[0, 0, 2, 2], [1, 1, 3, 3]], dtype=np.float32))
        reference, reference_scores = choose_masks(postprocess(low, (4, 5)).numpy(), quality.numpy())
        for actual, expected in zip(masks, reference):
            np.testing.assert_array_equal(actual, expected)
        self.assertEqual(scores, reference_scores)

    def test_highest_quality_mask_selected_not_largest(self):
        masks = np.zeros((2, 3, 4, 5), dtype=np.float32)
        masks[0, 0] = 1
        masks[0, 2, 1, 2] = 1
        masks[1, 1, 2, 3] = 1
        selected, scores = choose_masks(masks, [[0.2, 0.1, 0.9], [0.1, 0.8, 0.3]])
        self.assertEqual(selected[0].sum(), 1)
        self.assertTrue(selected[0][1, 2])
        self.assertTrue(selected[1][2, 3])
        self.assertEqual(scores, [0.9, 0.8])

    def test_single_box_output_and_non_finite_masks_never_fill_rectangles(self):
        selected, scores = choose_masks(np.ones((3, 4, 5)), np.array([0.1, 0.4, 0.2]))
        self.assertEqual(len(selected), 1)
        self.assertTrue(selected[0].all())
        selected, scores = choose_masks(np.full((1, 3, 4, 5), float("nan")), [[0.1, 0.5, 0.2]])
        self.assertFalse(selected[0].any())
        self.assertEqual(scores, [None])
        selected, scores = choose_masks(np.ones((1, 3, 4, 5)), [[float("nan")] * 3])
        self.assertFalse(selected[0].any())
        self.assertEqual(scores, [None])

    def test_order_ids_preserved_while_higher_confidence_wins_overlap(self):
        first = np.zeros((4, 5), bool)
        first[:, :3] = True
        second = np.zeros((4, 5), bool)
        second[:, 2:] = True
        result = compose_instance_map([first, second], [{"confidence": 0.3}, {"confidence": 0.8}], 5, 4)
        self.assertTrue((result[:, :2] == 1).all())
        self.assertTrue((result[:, 2:] == 2).all())
        self.assertEqual(result.dtype, np.uint8)

    def test_png_preserves_ids_without_palette_or_alpha_conversion(self):
        ids = np.array([[0, 1, 25], [100, 2, 0]], np.uint8)
        encoded = encode_instance_map(ids)
        self.assertEqual((encoded["width"], encoded["height"]), (3, 2))
        image = Image.open(io.BytesIO(base64.b64decode(encoded["data"])))
        self.assertEqual(image.mode, "L")
        np.testing.assert_array_equal(np.asarray(image), ids)

    def test_no_mask_fallback_and_invalid_shapes(self):
        with self.assertRaises(ValueError):
            compose_instance_map([np.ones((2, 2))], [{"confidence": 0.5}], 3, 4)
        with self.assertRaises(ValueError):
            choose_masks(np.zeros((1, 3, 4, 5)), np.zeros((1, 2)))
        with self.assertRaises(ValueError):
            encode_instance_map(np.zeros((2, 1025), np.uint8))
        result = compose_instance_map([np.zeros((2, 2))], [{"confidence": 0.5}], 2, 2)
        self.assertFalse(result.any())


if __name__ == "__main__":
    unittest.main()

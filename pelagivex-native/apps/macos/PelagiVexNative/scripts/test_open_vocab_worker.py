import base64
import io
import json
import unittest
from unittest.mock import patch

from open_vocab_worker import (
    MAX_IMAGE_BYTES, MAX_LINE_BYTES, MAX_PIXELS,
    decode_image, normalized_detections, parse_request,
)


class OpenVocabularyProtocolTests(unittest.TestCase):
    def request(self, **changes):
        request = {"image": base64.b64encode(b"not decoded in protocol validation").decode(),
                   "prompts": ["keyboard", "monitor"]}
        request.update(changes)
        return json.dumps(request).encode()

    def test_trim_and_deduplicate_queries_without_changing_first_spelling(self):
        image, prompts, threshold = parse_request(self.request(prompts=[" keyboard ", "Keyboard", "monitor"]))
        self.assertTrue(image)
        self.assertEqual(prompts, ["keyboard", "monitor"])
        self.assertEqual(threshold, 0.2)

    def test_query_limits_and_types(self):
        for prompts in ([], ["a"] * 33, "chair", [None], [""], [" "], ["a" * 129], ["foo\nbar"]):
            with self.subTest(prompts=prompts), self.assertRaises(ValueError):
                parse_request(self.request(prompts=prompts))
        self.assertEqual(len(parse_request(self.request(prompts=[f"object {n}" for n in range(32)]))[1]), 32)

    def test_threshold_range_and_non_finite_values(self):
        for threshold in (True, None, "0.2", 0.09, 0.71, float("nan"), float("inf")):
            with self.subTest(threshold=threshold), self.assertRaises(ValueError):
                parse_request(self.request(threshold=threshold))
        for threshold in (0.1, 0.7):
            self.assertEqual(parse_request(self.request(threshold=threshold))[2], threshold)

    def test_bad_json_and_image_payloads(self):
        for line in (b"[]", b"{}", b"{", b"null", b"\xff", b""):
            with self.subTest(line=line), self.assertRaises(ValueError):
                parse_request(line)
        for image in ("", "https://example.com/a.jpg", "/tmp/photo.jpg", "!invalid!", 1, None):
            with self.subTest(image=image), self.assertRaises(ValueError):
                parse_request(self.request(image=image))
        with self.assertRaises(ValueError):
            parse_request(b" " * (MAX_LINE_BYTES + 1))
        with self.assertRaises(ValueError):
            parse_request(self.request(image=base64.b64encode(b"x" * (MAX_IMAGE_BYTES + 1)).decode()))

    def test_source_boxes_are_clamped_and_bad_model_outputs_are_ignored(self):
        raw = [
            {"label": "monitor", "confidence": 0.8, "box": [-1, 1, 110, 60]},
            {"label": "chair", "confidence": 0.9, "box": [1, 1, 5, 5]},
            {"label": "monitor", "confidence": float("nan"), "box": [1, 1, 5, 5]},
            {"label": "monitor", "confidence": 0.8, "box": [1, 1, 0, 0]},
            {"label": "monitor", "confidence": 0.8, "box": [1, 1, float("inf"), 5]},
        ]
        self.assertEqual(normalized_detections(raw, 100, 50, ["monitor"]),
                         [{"label": "monitor", "confidence": 0.8, "box": [0, 0.02, 1, 1]}])
        with self.assertRaises(ValueError):
            normalized_detections([], 0, 50, ["monitor"])

    def test_maximum_detection_count_and_score_order(self):
        raw = [{"label": "monitor", "confidence": n / 100, "box": [1, 1, 9, 9]} for n in range(40)]
        out = normalized_detections(raw, 10, 10, ["monitor"])
        self.assertEqual(len(out), 25)
        self.assertAlmostEqual(out[0]["confidence"], 0.39)

    def test_jpeg_decode_checks_dimensions_and_format_without_loading_a_model(self):
        try:
            from PIL import Image
            import numpy  # noqa: F401
        except ImportError:
            self.skipTest("Pillow and NumPy unavailable")
        image = Image.new("RGB", (8, 6), "red")
        data = io.BytesIO()
        image.save(data, format="JPEG")
        self.assertEqual(decode_image(data.getvalue()).shape, (6, 8, 3))
        wrong_format = io.BytesIO()
        image.save(wrong_format, format="PNG")
        with self.assertRaises(ValueError):
            decode_image(wrong_format.getvalue())
        with self.assertRaises(Exception):
            decode_image(b"invalid jpeg")
        # Test dimension guard without allocating a multi-megapixel decoded image.
        with patch("PIL.Image.open") as opened:
            opened.return_value.__enter__.return_value.format = "JPEG"
            opened.return_value.__enter__.return_value.size = (MAX_PIXELS + 1, 1)
            with self.assertRaises(ValueError):
                decode_image(b"fake header")


if __name__ == "__main__":
    unittest.main()

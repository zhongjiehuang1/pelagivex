"""Offline OWLv2 JSON-lines worker for the native general-vision inspector.

Input: base64 JPEG, 1–32 English text queries, optional confidence threshold.
Output boxes are normalized source-image coordinates. No files or URLs are
accepted in incoming requests. Importing this module does not load a model.
"""
from __future__ import annotations

import base64
import binascii
import io
import json
import math
import os
from pathlib import Path
import sys
import time
from contextlib import redirect_stdout
import warnings

MAX_IMAGE_BYTES = 8 * 1024 * 1024
MAX_LINE_BYTES = 12 * 1024 * 1024
MAX_PIXELS = 4_000_000
MAX_BASE64_CHARS = 4 * ((MAX_IMAGE_BYTES + 2) // 3)


def request_object(line: bytes) -> dict:
    if not isinstance(line, bytes) or not line or len(line) > MAX_LINE_BYTES:
        raise ValueError("Provide one JSON request no larger than 12 MiB.")
    try:
        request = json.loads(line, parse_constant=lambda value: (_ for _ in ()).throw(ValueError("Non-finite JSON value.")))
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise ValueError("Invalid JSON request.") from error
    if not isinstance(request, dict):
        raise ValueError("The request must be a JSON object.")
    refine = request.get("refineOutlines", True)
    if not isinstance(refine, bool):
        raise ValueError("refineOutlines must be true or false.")
    return request


def image_bytes(request: dict) -> bytes:
    encoded = request.get("image")
    if not isinstance(encoded, str) or not encoded or len(encoded) > MAX_BASE64_CHARS:
        raise ValueError("Provide a base64 JPEG no larger than 8 MiB.")
    try:
        data = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError("Invalid base64 JPEG.") from error
    if not data or len(data) > MAX_IMAGE_BYTES:
        raise ValueError("Provide a JPEG no larger than 8 MiB.")
    return data


def parse_request(line: bytes) -> tuple[bytes, list[str], float]:
    request = request_object(line)
    prompts = request.get("prompts")
    if not isinstance(prompts, list) or not 1 <= len(prompts) <= 32:
        raise ValueError("Provide 1 to 32 text queries.")
    cleaned: list[str] = []
    seen: set[str] = set()
    for prompt in prompts:
        if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 128:
            raise ValueError("Each text query must contain 1 to 128 characters.")
        prompt = prompt.strip()
        if any(ord(char) < 32 for char in prompt):
            raise ValueError("Text queries cannot contain control characters.")
        if prompt.casefold() not in seen:
            seen.add(prompt.casefold())
            cleaned.append(prompt)
    threshold = request.get("threshold", 0.2)
    if isinstance(threshold, bool) or not isinstance(threshold, (int, float)) or not math.isfinite(threshold) or not 0.1 <= threshold <= 0.7:
        raise ValueError("Confidence threshold must be between 0.1 and 0.7.")
    return image_bytes(request), cleaned, float(threshold)


def parse_refinement_request(line: bytes) -> tuple[bytes, list[dict]]:
    request = request_object(line)
    entries = request.get("refineDetections")
    if not isinstance(entries, list) or not 1 <= len(entries) <= 100:
        raise ValueError("Provide 1 to 100 current-frame detections for outline refinement.")
    detections = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError("Each refinement detection must be an object.")
        label, confidence, box = entry.get("label"), entry.get("confidence"), entry.get("box")
        if not isinstance(label, str) or not label.strip() or len(label) > 128:
            raise ValueError("Each refinement detection requires a label.")
        if isinstance(confidence, bool) or not isinstance(confidence, (int, float)) or not math.isfinite(confidence) or not 0 <= confidence <= 1:
            raise ValueError("Each detection needs a finite confidence in [0,1].")
        if not isinstance(box, list) or len(box) != 4 or any(
            isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not 0 <= value <= 1 for value in box
        ) or box[2] <= box[0] or box[3] <= box[1]:
            raise ValueError("Each detection requires a positive normalized source-coordinate box.")
        detections.append({"label": label.strip(), "confidence": float(confidence), "box": [float(value) for value in box]})
    return image_bytes(request), detections


def decode_image(data: bytes):
    # Kept separate to let protocol tests run without importing torch/transformers.
    import numpy as np
    from PIL import Image

    with warnings.catch_warnings():
        warnings.simplefilter("error", Image.DecompressionBombWarning)
        with Image.open(io.BytesIO(data)) as image:
            width, height = image.size
            if image.format != "JPEG" or width < 1 or height < 1 or width * height > MAX_PIXELS:
                raise ValueError("Provide a JPEG of at most 4 megapixels.")
            return np.asarray(image.convert("RGB")).copy()


def normalized_detections(raw, width: int, height: int, prompts: list[str]) -> list[dict]:
    if width <= 0 or height <= 0:
        raise ValueError("Invalid image size.")
    result = []
    for entry in raw:
        try:
            label = entry["label"]
            score = float(entry["confidence"])
            values = entry["box"]
            if label not in prompts or not math.isfinite(score) or not 0 <= score <= 1 or len(values) != 4:
                continue
            box = [float(value) for value in values]
            if not all(map(math.isfinite, box)):
                continue
            x1, y1, x2, y2 = box
            box = [min(1.0, max(0.0, x1 / width)), min(1.0, max(0.0, y1 / height)),
                   min(1.0, max(0.0, x2 / width)), min(1.0, max(0.0, y2 / height))]
            if box[2] <= box[0] or box[3] <= box[1]:
                continue
            result.append({"label": label, "confidence": score, "box": box})
        except (KeyError, TypeError, ValueError, OverflowError):
            continue
    return sorted(result, key=lambda item: item["confidence"], reverse=True)[:25]


def emit(payload: dict):
    print(json.dumps(payload, allow_nan=False, separators=(",", ":")), flush=True)


def main() -> int:
    sys.dont_write_bytecode = True
    if len(sys.argv) != 2:
        emit({"error": "Usage: open_vocab_worker.py <local project root>"})
        return 1
    root = Path(sys.argv[1]).resolve()
    sys.path.insert(0, str(root / "local_vision"))
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["TOKENIZERS_PARALLELISM"] = "false"
    os.environ["OPENBLAS_NUM_THREADS"] = "1"
    os.environ["OMP_NUM_THREADS"] = "2"
    os.environ["VECLIB_MAXIMUM_THREADS"] = "1"
    os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
    try:
        with redirect_stdout(sys.stderr):
            import torch
            torch.set_num_threads(2)
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        emit({"ready": True, "model": "OWLv2 Base / SAM2.1 Tiny (on demand)", "device": device})
    except Exception as error:
        emit({"error": str(error)})
        return 1
    detector = None
    refiner = None
    stream = sys.stdin.buffer
    while True:
        line = stream.readline(MAX_LINE_BYTES + 1)
        if not line:
            return 0
        if len(line) > MAX_LINE_BYTES:
            # Drain this oversized request rather than treating its tail as new JSON.
            while line and not line.endswith(b"\n"):
                line = stream.readline(1024 * 1024)
            emit({"error": "JSON request exceeds 12 MiB."})
            continue
        try:
            started = time.perf_counter()
            message = request_object(line)
            if "refineDetections" in message:
                data, detections = parse_refinement_request(line)
                image = decode_image(data)
                model = "SAM2.1 Tiny (current-frame detection refinement)"
            else:
                data, prompts, threshold = parse_request(line)
                image = decode_image(data)
                with redirect_stdout(sys.stderr):
                    if detector is None:
                        from owl_detector import OwlDetector
                        detector = OwlDetector()
                    detector.threshold = threshold
                    raw = detector.detect(image, prompts)
                height, width = image.shape[:2]
                detections = normalized_detections(raw, width, height, prompts)
                model = detector.info["model"]
            response = {"detections": detections, "model": model, "device": device}
            if message.get("refineOutlines", True) and detections:
                segmentation_started = time.perf_counter()
                load_seconds = 0
                try:
                    with redirect_stdout(sys.stderr):
                        if refiner is None:
                            from segmentation_refiner import SegmentationRefiner
                            refiner = SegmentationRefiner(root)
                            load_seconds = refiner.load_seconds
                        mask, scores = refiner.refine(image, detections)
                    response.update({
                        "instanceMask": mask, "segmentationScores": scores,
                        "segmentationModel": refiner.model,
                        "segmentationTimings": refiner.last_timings,
                    })
                except Exception as error:
                    # Keep classification results, but do not substitute a rectangular
                    # mask when the independent segmentation model could not refine it.
                    response["segmentationError"] = str(error)
                response.update({
                    "segmentationLoadSeconds": load_seconds,
                    "segmentationSeconds": time.perf_counter() - segmentation_started,
                })
            response["workerSeconds"] = time.perf_counter() - started
            emit(response)
        except Exception as error:
            emit({"error": str(error)})


if __name__ == "__main__":
    raise SystemExit(main())

"""Local SAM2.1 Tiny outlines, prompted by current-frame detected boxes.

The instance map uses IDs matching the input order, not semantic labels. Higher
classification confidence wins overlapping pixels; failed masks remain empty.
"""
from __future__ import annotations

import base64
import io
import math
from pathlib import Path
import sys
import time


def output_size(width: int, height: int, maximum: int = 1024) -> tuple[int, int]:
    if width < 1 or height < 1 or maximum < 1:
        raise ValueError("Positive image dimensions required.")
    scale = min(1.0, maximum / max(width, height))
    return max(1, round(width * scale)), max(1, round(height * scale))


def choose_masks(masks, qualities):
    """Select the highest finite predicted-IoU mask per box, with no box fill."""
    import numpy as np
    masks = np.asarray(masks)
    qualities = np.asarray(qualities)
    if masks.ndim == 3:
        masks = masks[None, ...]
    if qualities.ndim == 1:
        qualities = qualities[None, ...]
    if masks.ndim != 4 or qualities.shape != masks.shape[:2]:
        raise ValueError("SAM returned incompatible masks and quality scores.")
    selected, scores = [], []
    for candidates, values in zip(masks, qualities):
        valid = np.isfinite(values)
        if not valid.any():
            selected.append(np.zeros(candidates.shape[-2:], dtype=bool))
            scores.append(None)
            continue
        best = int(np.argmax(np.where(valid, values, -np.inf)))
        mask = candidates[best]
        if not np.isfinite(mask).all():
            selected.append(np.zeros(mask.shape, dtype=bool))
            scores.append(None)
        else:
            selected.append(mask.astype(bool) if mask.dtype == bool else mask > 0)
            scores.append(float(values[best]))
    return selected, scores


def compose_instance_map(masks, detections, width: int, height: int):
    import numpy as np
    if len(masks) != len(detections) or len(masks) > 100 or width < 1 or height < 1:
        raise ValueError("One source-sized mask is required per detection, at most 100.")
    result = np.zeros((height, width), dtype=np.uint8)
    order = sorted(range(len(detections)), key=lambda i: (-detections[i]["confidence"], i))
    for index in order:
        mask = np.asarray(masks[index])
        if mask.shape != (height, width):
            raise ValueError("Mask coordinates do not match the source image.")
        if not np.isfinite(mask).all():
            continue
        result[(mask.astype(bool)) & (result == 0)] = index + 1
    return result


def instance_priorities(detections):
    """Exact confidence ordering as integer ranks, preserving double-valued ties."""
    import numpy as np
    if not 1 <= len(detections) <= 100:
        raise ValueError("Provide 1 to 100 detections.")
    priorities = [0] * len(detections)
    lookup = np.zeros(len(detections) + 1, dtype=np.uint8)
    order = sorted(range(len(detections)), key=lambda i: (-detections[i]["confidence"], i))
    for rank, index in enumerate(order):
        priority = len(detections) - rank
        priorities[index] = priority
        lookup[priority] = index + 1
    return priorities, lookup


def merge_priority_masks(current, masks, priorities):
    """Associative integer composition; independent of chunk size and order."""
    import torch
    if masks.ndim != 3 or len(masks) != len(priorities) or tuple(current.shape) != tuple(masks.shape[1:]):
        raise ValueError("Source-sized masks and matching priorities required.")
    ranks = torch.as_tensor(priorities, dtype=torch.int32, device=masks.device)
    strongest = torch.amax(masks.to(torch.int32) * ranks[:, None, None], dim=0)
    return torch.maximum(current, strongest)


def encode_instance_map(instance_map) -> dict:
    import numpy as np
    from PIL import Image
    data = np.asarray(instance_map)
    if data.dtype != np.uint8 or data.ndim != 2 or not data.size or max(data.shape) > 1024:
        raise ValueError("Instance map must be a nonempty 8-bit image with longest edge <=1024.")
    image = Image.fromarray(data)
    encoded = io.BytesIO()
    image.save(encoded, format="PNG", compress_level=3)
    height, width = data.shape
    return {"width": width, "height": height, "data": base64.b64encode(encoded.getvalue()).decode("ascii")}


class SegmentationRefiner:
    def __init__(self, root: Path):
        started = time.perf_counter()
        source = root / ".cache" / "sam2-source"
        dependencies = root / ".cache" / "sam2-deps"
        checkpoint = root / ".cache" / "sam2.1-tiny" / "sam2.1_hiera_tiny.pt"
        if not (source / "sam2" / "build_sam.py").is_file() or not checkpoint.is_file():
            raise FileNotFoundError("Local SAM2.1 Tiny source/checkpoint missing; see GENERAL_VISION.md setup.")
        sys.path[:0] = [str(source), str(dependencies)]
        import torch
        from sam2.build_sam import build_sam2
        from sam2.sam2_image_predictor import SAM2ImagePredictor
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"
        model = build_sam2("configs/sam2.1/sam2.1_hiera_t.yaml", str(checkpoint),
                           device=self.device, apply_postprocessing=False)
        self.predictor = SAM2ImagePredictor(model)
        self.model = "Meta SAM2.1 Hiera Tiny"
        self.load_seconds = time.perf_counter() - started
        self.last_timings = {}

    def _synchronize(self):
        import torch
        if self.device == "mps":
            torch.mps.synchronize()

    def _predict_selected_tensors(self, boxes):
        """Same best-IoU masks as the pinned Meta predictor, without unused transfers.

        The reference public predict() upsamples all three candidates and copies
        those float masks plus low-resolution logits to CPU. Select on MPS first,
        then upsample only one binary mask per box. Keep it on-device so the
        default path can compose before transferring one final map. This preserves
        multimask generation and selection; it is not single-mask approximation.
        """
        import torch
        predictor = self.predictor
        _, _, _, transformed = predictor._prep_prompts(None, None, boxes, None, True)
        points = transformed.reshape(-1, 2, 2)
        labels = torch.tensor([[2, 3]], dtype=torch.int, device=points.device).repeat(len(points), 1)
        sparse, dense = predictor.model.sam_prompt_encoder(points=(points, labels), boxes=None, masks=None)
        high_resolution = [level[-1].unsqueeze(0) for level in predictor._features["high_res_feats"]]
        low_resolution, quality, _, _ = predictor.model.sam_mask_decoder(
            image_embeddings=predictor._features["image_embed"][-1].unsqueeze(0),
            image_pe=predictor.model.sam_prompt_encoder.get_dense_pe(),
            sparse_prompt_embeddings=sparse, dense_prompt_embeddings=dense,
            multimask_output=True, repeat_image=len(points) > 1,
            high_res_features=high_resolution,
        )
        finite_quality = torch.isfinite(quality)
        best = torch.where(finite_quality, quality, -torch.inf).argmax(dim=1)
        rows = torch.arange(len(points), device=points.device)
        selected_quality = quality[rows, best]
        selected_logits = low_resolution[rows, best].unsqueeze(1)
        logits = predictor._transforms.postprocess_masks(selected_logits, predictor._orig_hw[-1])
        valid = finite_quality.any(dim=1) & torch.isfinite(logits).flatten(1).all(dim=1)
        masks = (logits[:, 0] > 0) & valid[:, None, None]
        values = torch.where(valid, selected_quality, torch.nan)
        return masks, values

    def _predict_selected(self, boxes):
        # Kept for reference parity checks; the default path composes on-device
        # before making a single final instance-map transfer.
        masks, quality = self._predict_selected_tensors(boxes)
        values = quality.detach().cpu().numpy()
        return list(masks.detach().cpu().numpy()), [float(value) if math.isfinite(value) else None for value in values]

    def refine(self, image, detections, *, reference=False, compose_on_device=True):
        import numpy as np
        import torch
        from PIL import Image
        if not isinstance(image, np.ndarray) or image.dtype != np.uint8 or image.ndim != 3 or image.shape[2] != 3:
            raise ValueError("SAM refinement expects an RGB uint8 image.")
        if not 1 <= len(detections) <= 100:
            raise ValueError("Provide 1 to 100 current-frame detections for outline refinement.")
        started = time.perf_counter()
        source_height, source_width = image.shape[:2]
        width, height = output_size(source_width, source_height)
        if (width, height) != (image.shape[1], image.shape[0]):
            image = np.asarray(Image.fromarray(image).resize((width, height), Image.Resampling.LANCZOS)).copy()
        boxes = np.asarray([entry["box"] for entry in detections], dtype=np.float32)
        if boxes.shape != (len(detections), 4) or not np.isfinite(boxes).all():
            raise ValueError("Each detection needs four finite normalized box coordinates.")
        boxes = boxes * np.asarray([width, height, width, height], dtype=np.float32)
        masks, scores = [], []
        device_composition = not reference and compose_on_device
        priorities, lookup = instance_priorities(detections)
        priority_map = None
        device_scores = []
        self._synchronize()
        prepared = time.perf_counter()
        with torch.inference_mode():
            self.predictor.set_image(image)
            self._synchronize()
            encoded = time.perf_counter()
            # Reuse the image embedding while bounding decoder memory for busy scenes.
            for first in range(0, len(detections), 8):
                if reference:
                    raw, quality, _ = self.predictor.predict(
                        box=boxes[first:first+8], multimask_output=True, return_logits=True)
                    chosen, selected_scores = choose_masks(raw, quality)
                elif device_composition:
                    chosen, selected_scores = self._predict_selected_tensors(boxes[first:first+8])
                    if priority_map is None:
                        priority_map = torch.zeros((height, width), dtype=torch.int32, device=chosen.device)
                    priority_map = merge_priority_masks(priority_map, chosen, priorities[first:first+8])
                    device_scores.append(selected_scores)
                else:
                    chosen, selected_scores = self._predict_selected(boxes[first:first+8])
                if not device_composition:
                    masks.extend(chosen)
                    scores.extend(selected_scores)
        self._synchronize()
        decoded = time.perf_counter()
        if not device_composition:
            instance_map = compose_instance_map(masks, detections, width, height)
        else:
            # One final byte map rather than N full-resolution masks and a CPU fence
            # after every decoder chunk. Integer rank lookup preserves original IDs.
            instance_map = lookup[priority_map.to(torch.uint8).detach().cpu().numpy()]
            quality_values = torch.cat(device_scores).detach().cpu().numpy()
            scores = [float(value) if math.isfinite(value) else None for value in quality_values]
        composed = time.perf_counter()
        result = encode_instance_map(instance_map)
        finished = time.perf_counter()
        self.last_timings = {
            "prepareSeconds": prepared-started, "imageEncoderSeconds": encoded-prepared,
            "maskDecoderAndSelectionSeconds": decoded-encoded, "compositionSeconds": composed-decoded,
            "pngSeconds": finished-composed, "totalSeconds": finished-started,
            "width": width, "height": height, "instances": len(detections),
            "sourceWidth": source_width, "sourceHeight": source_height,
            "multimaskSelection": "referenceCPU" if reference else
                "selectedAndComposedOnDevice" if device_composition else "selectedOnDevice",
            "compositionOnDevice": device_composition,
            "decoderTimingIncludesComposition": device_composition,
        }
        return result, scores

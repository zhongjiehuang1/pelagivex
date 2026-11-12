#!/usr/bin/env python3
"""Experimental SAM2.1 Tiny fixed-1024 Core ML encoder, never the app default.

Use the pinned local Meta source/checkpoint and isolated coremltools install.
Export three decoder-ready feature tensors, then compare FP16 Core ML features
and final instance masks with the existing FP32 MPS implementation. Overlap is
implementation stability on public RGB-D frames, not segmentation accuracy.

Example, from the repository root:
  .venv-model/bin/python pelagivex-native/apps/macos/PelagiVexNative/scripts/experiment_sam_coreml.py --phase export
  .venv-model/bin/python pelagivex-native/apps/macos/PelagiVexNative/scripts/experiment_sam_coreml.py --phase benchmark --runs 5

Add --variant attention-norm32 for the mixed candidate. CPU_ONLY is the default;
ALL and CPU_AND_NE are opt-in because the tested versions hit a native Metal
assertion and prolonged ANE compilation respectively on this machine.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import time


FEATURE_NAMES = ("high_res_0", "high_res_1", "image_embed")
CONFIG = "configs/sam2.1/sam2.1_hiera_t.yaml"
PRIMARY_SOURCES = {
    "sam2": "https://github.com/facebookresearch/sam2",
    "checkpoint": "https://huggingface.co/facebook/sam2.1-hiera-tiny/resolve/de431c4/sam2.1_hiera_tiny.pt",
    "apple_sam2_1": "https://huggingface.co/apple/coreml-sam2.1-tiny",
    "apple_sam2_conversion_fork": "https://github.com/huggingface/segment-anything-2/tree/fce694ed6c90a7caf14b69d5c833f0d44db9a217/coreml",
    "apple_conversion": "https://apple.github.io/coremltools/docs-guides/source/convert-pytorch-workflow.html",
    "apple_prediction": "https://apple.github.io/coremltools/docs-guides/source/model-prediction.html",
}


def digest(path):
    sha = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def load_dependencies(root):
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    sys.path[:0] = [str(root / ".cache/yoloe26/coreml-deps"),
                    str(root / ".cache/sam2-source"), str(root / ".cache/sam2-deps")]
    import coremltools as ct
    import numpy as np
    import torch
    torch.set_num_threads(2)
    return ct, np, torch


def encoder_wrapper(torch, sam):
    class DecoderReadyEncoder(torch.nn.Module):
        def __init__(self, model):
            super().__init__()
            self.encoder = model.image_encoder
            # Fixed resolution makes this learned bicubic interpolation constant.
            # coremltools9 cannot convert aten::upsample_bicubic2d. Compute it once
            # with Meta's own function, without replacing it with another resize.
            with torch.no_grad():
                positional = self.encoder.trunk._get_pos_embed((256, 256)).detach().clone()
            self.register_buffer("fixed_pos_embed", positional)
            self.conv_s0 = model.sam_mask_decoder.conv_s0
            self.conv_s1 = model.sam_mask_decoder.conv_s1
            self.register_buffer("no_mem_embed", model.no_mem_embed.detach().reshape(1, -1, 1, 1).clone())
            self.add_no_mem = bool(model.directly_add_no_mem_embed)

        def forward(self, image):
            trunk = self.encoder.trunk
            value = trunk.patch_embed(image) + self.fixed_pos_embed
            levels = []
            for index, block in enumerate(trunk.blocks):
                value = block(value)
                if index == trunk.stage_ends[-1] or (index in trunk.stage_ends and trunk.return_interm_layers):
                    levels.append(value.permute(0, 3, 1, 2))
            features, _ = self.encoder.neck(levels)
            if self.encoder.scalp > 0:
                features = features[:-self.encoder.scalp]
            low = features[-1]
            if self.add_no_mem:
                low = low + self.no_mem_embed
            return self.conv_s0(features[0]), self.conv_s1(features[1]), low

    return DecoderReadyEncoder(sam).eval()


def provenance(root, ct, torch):
    checkpoint = root / ".cache/sam2.1-tiny/sam2.1_hiera_tiny.pt"
    source = root / ".cache/sam2-source"
    commit = subprocess.run(["git", "-C", str(source), "rev-parse", "HEAD"],
                            check=True, capture_output=True, text=True).stdout.strip()
    return {
        "experiment": "SAM2.1 Hiera Tiny decoder-ready encoder Core ML FP16",
        "productionChanged": False, "samSourceCommit": commit,
        "checkpoint": str(checkpoint.relative_to(root)), "checkpointSHA256": digest(checkpoint),
        "config": CONFIG, "sources": PRIMARY_SOURCES,
        "python": sys.version, "torch": torch.__version__, "coremltools": ct.__version__,
        "macOS": platform.mac_ver()[0], "machine": platform.machine(),
        "preprocessing": "Original SAM2Transforms: RGB uint8 -> ToTensor -> Resize(1024,1024) -> ImageNet normalization; tensor input has no additional Core ML preprocessing.",
        "features": list(FEATURE_NAMES),
        "scope": "Fixed one-image image encoder including conv_s0/conv_s1 and no_mem_embed; existing FP32 MPS prompt/mask decoder retained.",
    }


def export(root, destination, ct, np, torch, variant):
    from sam2.build_sam import build_sam2
    started = time.perf_counter()
    model = build_sam2(CONFIG, str(root / ".cache/sam2.1-tiny/sam2.1_hiera_tiny.pt"),
                       device="cpu", apply_postprocessing=False)
    wrapper = encoder_wrapper(torch, model)
    sample = torch.zeros((1, 3, 1024, 1024), dtype=torch.float32)
    with torch.inference_mode():
        outputs = wrapper(sample)
        native = model.forward_image(sample)["backbone_fpn"]
        native[-1] = native[-1] + model.no_mem_embed.reshape(1, -1, 1, 1)
        exact = all(torch.equal(first, second) for first, second in zip(outputs, native))
        if not exact:
            raise AssertionError("Fixed positional embedding wrapper must exactly match original FP32 encoder.")
        traced = torch.jit.trace(wrapper, sample, check_trace=False, strict=False)
    traced.save(str(destination / "encoder-fp32-trace.pt"))
    print("Trace complete", [list(value.shape) for value in outputs], flush=True)
    protected = {"layer_norm", "scaled_dot_product_attention", "softmax"}
    precision = (ct.transform.FP16ComputePrecision(op_selector=lambda operation: operation.op_type not in protected)
                 if variant == "attention-norm32" else ct.precision.FLOAT16)
    converted = ct.convert(
        traced, source="pytorch", convert_to="mlprogram",
        inputs=[ct.TensorType(name="image", shape=(1, 3, 1024, 1024), dtype=np.float32)],
        outputs=[ct.TensorType(name=name, dtype=np.float32) for name in FEATURE_NAMES],
        compute_precision=precision, minimum_deployment_target=ct.target.macOS15,
        skip_model_load=True,
    )
    converted.short_description = "Experimental fixed1024 SAM2.1 Tiny image encoder; decoder-ready feature tensors"
    converted.author = "Meta SAM2 checkpoint; PelagiVex local experimental conversion"
    converted.license = "Apache-2.0 (Meta SAM2 source/checkpoint)"
    converted.user_defined_metadata["sam2_source_commit"] = provenance(root, ct, torch)["samSourceCommit"]
    path = destination / "encoder-fp16.mlpackage"
    converted.save(str(path))
    metadata = provenance(root, ct, torch)
    metadata.update({"artifact": str(path.relative_to(root)),
                     "featureShapes": {key: list(value.shape) for key, value in zip(FEATURE_NAMES, outputs)},
                     "exportSeconds": time.perf_counter() - started,
                     "fixedPositionEmbeddingFP32ExactParity": exact,
                     "weightsSHA256": digest(path / "Data/com.apple.CoreML/weights/weight.bin"),
                     "minimumDeploymentTarget": "macOS15", "variant": variant,
                     "protectedFP32OperationTypes": sorted(protected) if variant == "attention-norm32" else [],
                     "precision": "FP16 internal / FP32 input-output; protected operations listed explicitly"})
    (destination / "export.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print("Export complete", path, metadata["exportSeconds"], flush=True)


def public_cases(root, np):
    from PIL import Image
    from segmentation_refiner import output_size
    cases = []
    for name, folder, target in [("chairs", "bonn-chairs-near", 0), ("crowd", "bonn-crowd3", 6.2)]:
        base = root / ".cache/pair-study" / folder
        manifest = json.loads((base / "manifest.json").read_text())
        trace = json.loads((base / "trace.json").read_text())
        index = min(range(len(trace["frames"])), key=lambda i: abs(trace["frames"][i]["time"] - target))
        frame, source = trace["frames"][index], manifest["frames"][index]
        if source["time"] != frame["time"]:
            raise ValueError("Public frame manifest and detection trace times differ.")
        image = Image.open(base / source["image"]).convert("RGB")
        image = image.resize(output_size(*image.size), Image.Resampling.LANCZOS)
        image = np.asarray(image).copy()
        detections = [{"label": entry["name"], "confidence": entry["score"], "box": entry["box"]}
                      for entry in frame["detections"]]
        cases.append({"name": name, "image": image, "detections": detections,
                      "source": str((base / source["image"]).relative_to(root)), "time": source["time"]})
    return cases


def decode_map(payload, np):
    from PIL import Image
    return np.asarray(Image.open(io.BytesIO(base64.b64decode(payload["data"]))))


def map_stability(reference, actual, count, np):
    scores = []
    for index in range(1, count + 1):
        first, second = reference == index, actual == index
        union = int((first | second).sum())
        scores.append(float((first & second).sum()) / union if union else 1.0)
    return {"differentPixels": int((reference != actual).sum()),
            "differentPixelFraction": float((reference != actual).mean()), "perInstanceIoU": scores}


def feature_stability(reference, actual, np):
    records = {}
    for name in FEATURE_NAMES:
        baseline = np.asarray(reference[name], dtype=np.float64)
        candidate = np.asarray(actual[name], dtype=np.float64)
        difference = candidate - baseline
        finite = bool(np.isfinite(candidate).all())
        if not finite:
            records[name] = {"shape": list(candidate.shape), "allFinite": False,
                             "nonfiniteElements": int((~np.isfinite(candidate)).sum())}
            continue
        norm = float(np.linalg.norm(baseline.ravel()))
        candidate_norm = float(np.linalg.norm(candidate.ravel()))
        records[name] = {
            "shape": list(candidate.shape), "allFinite": finite,
            "meanAbsoluteError": float(np.abs(difference).mean()),
            "maxAbsoluteError": float(np.abs(difference).max()),
            "relativeL2Error": float(np.linalg.norm(difference.ravel())) / max(norm, 1e-12),
            "cosineSimilarity": float(np.dot(candidate.ravel(), baseline.ravel())) / max(norm * candidate_norm, 1e-12),
        }
    return records


def decode_features(refiner, features, image, detections, np, torch):
    """Same decoder/selection/composition as production, new encoder tensors only."""
    from segmentation_refiner import instance_priorities, merge_priority_masks, encode_instance_map
    height, width = image.shape[:2]
    predictor = refiner.predictor
    predictor.reset_predictor()
    converted = [torch.from_numpy(np.array(features[name], dtype=np.float32, copy=True)).to(refiner.device)
                 for name in FEATURE_NAMES]
    predictor._features = {"high_res_feats": converted[:2], "image_embed": converted[2]}
    predictor._orig_hw = [(height, width)]
    predictor._is_image_set = True
    boxes = np.asarray([entry["box"] for entry in detections], dtype=np.float32)
    boxes *= np.asarray([width, height, width, height], dtype=np.float32)
    priorities, lookup = instance_priorities(detections)
    priority_map = torch.zeros((height, width), dtype=torch.int32, device=refiner.device)
    qualities = []
    with torch.inference_mode():
        for first in range(0, len(detections), 8):
            masks, scores = refiner._predict_selected_tensors(boxes[first:first + 8])
            priority_map = merge_priority_masks(priority_map, masks, priorities[first:first + 8])
            qualities.append(scores)
    rank_map = priority_map.to(torch.uint8).cpu().numpy()
    quality = torch.cat(qualities).cpu().numpy()
    payload = encode_instance_map(lookup[rank_map])
    return payload, quality.tolist()


def compute_plan_summary(model, unit, ct):
    """Static planned device placement, not a hardware utilization measurement."""
    from coremltools.models.compute_plan import MLComputePlan
    try:
        plan = MLComputePlan.load_from_path(model.get_compiled_model_path(),
                                           compute_units=getattr(ct.ComputeUnit, unit))
        counts, weights, operations = {}, {}, []

        def visit(block):
            for operation in block.operations:
                usage = plan.get_compute_device_usage_for_mlprogram_operation(operation)
                cost = plan.get_estimated_cost_for_mlprogram_operation(operation)
                device = type(usage.preferred_compute_device).__name__ if usage else "unknown"
                weight = cost.weight if cost else None
                counts[device] = counts.get(device, 0) + 1
                if weight is not None:
                    weights[device] = weights.get(device, 0.0) + weight
                operations.append({"operator": operation.operator_name, "preferredDevice": device,
                                   "estimatedCostWeight": weight,
                                   "outputs": [entry.name for entry in operation.outputs]})
                for nested in operation.blocks:
                    visit(nested)

        for function in plan.model_structure.program.functions.values():
            visit(function.block)
        return {"plannedOperationCounts": counts, "plannedCostWeights": weights, "operations": operations}
    except Exception as error:
        return {"error": repr(error)}


def cpu_probe(root, destination, ct, np, torch):
    """Numerical gate before requesting any GPU/ANE benchmark resources."""
    from sam2.build_sam import build_sam2
    from sam2.sam2_image_predictor import SAM2ImagePredictor
    model = build_sam2(CONFIG, str(root / ".cache/sam2.1-tiny/sam2.1_hiera_tiny.pt"),
                       device="cpu", apply_postprocessing=False)
    predictor = SAM2ImagePredictor(model)
    coreml = ct.models.MLModel(str(destination / "encoder-fp16.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
    records = []
    for case in public_cases(root, np):
        with torch.inference_mode():
            predictor.set_image(case["image"])
        reference = {"high_res_0": predictor._features["high_res_feats"][0].numpy(),
                     "high_res_1": predictor._features["high_res_feats"][1].numpy(),
                     "image_embed": predictor._features["image_embed"].numpy()}
        tensor = predictor._transforms(case["image"])[None].numpy()
        started = time.perf_counter()
        actual = coreml.predict({"image": tensor})
        record = {"case": case["name"], "cpuPredictSeconds": time.perf_counter() - started,
                  "featuresVsFP32CPU": feature_stability(reference, actual, np)}
        records.append(record)
        print("CPU numerical probe", record, flush=True)
    report = provenance(root, ct, torch)
    report["records"] = records
    (destination / "cpu-probe.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")


def benchmark(root, destination, ct, np, torch, units, runs):
    from segmentation_refiner import SegmentationRefiner
    from PIL import Image
    refiner = SegmentationRefiner(root)
    records = []
    cases = public_cases(root, np)
    reference_features, reference_maps = {}, {}
    report = provenance(root, ct, torch)
    report.update({"records": records, "measuredRunsAfterTwoWarmups": runs,
                   "qualityScope": "Agreement with FP32 MPS on two public Bonn RGB-D frames, without segmentation ground truth.",
                   "computeUnitCaveat": "ComputePlan is static placement; CPU_AND_NE excludes GPU but does not guarantee ANE execution, and ALL permits CPU/GPU/ANE.",
                   "timingScope": "Hybrid includes original CPU transform, MLModel.predict, CPU-output to MPS features, unchanged FP32 decoder, instance composition and PNG; source decoding/model loading excluded.",
                   "notMeasured": ["sustained live camera FPS", "ground-truth segmentation accuracy", "concurrent detector throughput"]})

    def persist(stage, unit=None):
        report.update({"stage": stage, "currentComputeUnits": unit})
        (destination / "results.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")

    for case in cases:
        samples = []
        for index in range(runs + 2):
            payload, quality = refiner.refine(case["image"], case["detections"])
            if index >= 2:
                samples.append(dict(refiner.last_timings))
        name = case["name"]
        reference_maps[name] = decode_map(payload, np)
        reference_features[name] = {
            "high_res_0": refiner.predictor._features["high_res_feats"][0].cpu().numpy(),
            "high_res_1": refiner.predictor._features["high_res_feats"][1].cpu().numpy(),
            "image_embed": refiner.predictor._features["image_embed"].cpu().numpy(),
        }
        bridge_payload, _ = decode_features(refiner, reference_features[name], case["image"], case["detections"], np, torch)
        bridge = map_stability(reference_maps[name], decode_map(bridge_payload, np), len(case["detections"]), np)
        if bridge["differentPixels"]:
            raise AssertionError("Reference features must reproduce the original instance map through the bridge.")
        Image.fromarray(reference_maps[name]).save(destination / f"{name}-fp32-mps.png")
        median = statistics.median(sample["totalSeconds"] for sample in samples)
        records.append({"case": name, "computeUnits": "FP32_MPS_REFERENCE", "instances": len(case["detections"]),
                        "medianFullSeconds": median,
                        "medianImageEncoderSeconds": statistics.median(sample["imageEncoderSeconds"] for sample in samples),
                        "source": case["source"], "sourceTime": case["time"], "exactFeatureBridgeControl": bridge,
                        "samples": samples})
        print(name, "FP32_MPS_REFERENCE", median, flush=True)
    for unit in units:
        persist("loading", unit)
        load_started = time.perf_counter()
        model = ct.models.MLModel(str(destination / "encoder-fp16.mlpackage"),
                                  compute_units=getattr(ct.ComputeUnit, unit),
                                  optimization_hints={"specializationStrategy": ct.SpecializationStrategy.FastPrediction})
        load_seconds = time.perf_counter() - load_started
        plan = compute_plan_summary(model, unit, ct)
        (destination / f"compute-plan-{unit.lower()}.json").write_text(json.dumps(plan, indent=2) + "\n")
        persist("predicting", unit)
        for case in cases:
            samples = []
            for index in range(runs + 2):
                refiner._synchronize()
                started = time.perf_counter()
                tensor = refiner.predictor._transforms(case["image"])[None].numpy()
                prepared = time.perf_counter()
                result = model.predict({"image": tensor})
                encoded = time.perf_counter()
                payload, scores = decode_features(refiner, result, case["image"], case["detections"], np, torch)
                refiner._synchronize()
                finished = time.perf_counter()
                if index >= 2:
                    samples.append({"prepareSeconds": prepared - started, "coreMLEncoderSeconds": encoded - prepared,
                                    "featureTransferDecoderComposePNGSeconds": finished - encoded,
                                    "fullSeconds": finished - started})
            name = case["name"]
            candidate = decode_map(payload, np)
            Image.fromarray(candidate).save(destination / f"{name}-{unit.lower()}.png")
            np.savez_compressed(destination / f"{name}-{unit.lower()}-features.npz", **result)
            record = {
                "case": name, "computeUnits": unit, "instances": len(case["detections"]),
                "source": case["source"], "sourceTime": case["time"], "loadSeconds": load_seconds,
                "medianFullSeconds": statistics.median(sample["fullSeconds"] for sample in samples),
                "medianCoreMLEncoderSeconds": statistics.median(sample["coreMLEncoderSeconds"] for sample in samples),
                "samples": samples, "featuresVsFP32MPS": feature_stability(reference_features[name], result, np),
                "maskStabilityVsFP32MPS": map_stability(reference_maps[name], candidate, len(case["detections"]), np),
                "maskScores": [value if np.isfinite(value) else None for value in scores],
                "computePlan": {key: value for key, value in plan.items() if key != "operations"},
            }
            records.append(record)
            print(name, unit, record["medianCoreMLEncoderSeconds"], record["medianFullSeconds"],
                  record["maskStabilityVsFP32MPS"], flush=True)
            # Preserve partial results if a subsequent compute-unit load fails.
            persist("predicting", unit)
        del model
    persist("complete")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[5])
    parser.add_argument("--phase", choices=("export", "cpu-probe", "benchmark", "all"), default="all")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--variant", choices=("fp16", "attention-norm32"), default="fp16")
    parser.add_argument("--compute-units", default="CPU_ONLY")
    args = parser.parse_args()
    units = args.compute_units.split(",")
    if args.runs < 1 or any(unit not in ("CPU_ONLY", "CPU_AND_NE", "ALL") for unit in units):
        parser.error("Positive runs and CPU_ONLY,CPU_AND_NE,ALL compute units required.")
    root = args.root.resolve()
    destination = root / ".cache/model-sam-experiment"
    if args.variant != "fp16":
        destination = destination / args.variant
    destination.mkdir(parents=True, exist_ok=True)
    ct, np, torch = load_dependencies(root)
    try:
        if args.phase in ("export", "all"):
            export(root, destination, ct, np, torch, args.variant)
        if args.phase == "cpu-probe":
            cpu_probe(root, destination, ct, np, torch)
        if args.phase in ("benchmark", "all"):
            benchmark(root, destination, ct, np, torch, units, args.runs)
    except Exception as error:
        failure = provenance(root, ct, torch)
        failure.update({"phase": args.phase, "error": repr(error)})
        (destination / "failure.json").write_text(json.dumps(failure, indent=2) + "\n")
        raise


if __name__ == "__main__":
    main()

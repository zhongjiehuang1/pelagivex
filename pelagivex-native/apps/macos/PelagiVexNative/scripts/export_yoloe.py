#!/usr/bin/env python3
"""Export the official YOLOE26 prompt-free segmenter without changing the baseline.

Use the project's isolated Python environment. A local official checkpoint and a
real RGB frame are required; this script never silently downloads weights.
Core ML and PyTorch receive the exact same saved square, letterboxed RGB inputs.
This is conversion verification, not a model accuracy or camera benchmark.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import platform
import shutil
import tempfile
import time


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def inspect_shapes(outputs: dict[str, list[int]]) -> dict:
    prototypes = [(name, shape) for name, shape in outputs.items()
                  if len(shape) == 4 and shape[0] == 1 and 1 <= shape[1] <= 128]
    if len(prototypes) != 1:
        raise ValueError(f"Expected one NCHW prototype tensor: {outputs}")
    prototype_name, prototype = prototypes[0]
    predictions = [(name, shape) for name, shape in outputs.items()
                   if len(shape) == 3 and shape[0] == 1
                   and shape[2] == 6 + prototype[1] and 1 <= shape[1] <= 1000]
    if len(predictions) != 1:
        raise ValueError(f"Expected one [1,detections,6+mask_channels] end-to-end tensor: {outputs}")
    prediction_name, prediction = predictions[0]
    return dict(predictionName=prediction_name, prototypeName=prototype_name,
                maskChannels=prototype[1], prototypeHeight=prototype[2],
                prototypeWidth=prototype[3], predictionCount=prediction[1])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--real-frame", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--size", type=int, choices=(384, 512, 640, 768), default=640)
    # A 4,585-class index cannot be represented exactly in FP16 above 2,048.
    # The official all-FP16 conversion has been observed to change real labels.
    parser.add_argument("--quantize", type=int, choices=(16, 32), default=32)
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("Export and prediction verification require an Apple Silicon Mac.")
    checkpoint = args.checkpoint.expanduser().resolve(strict=True)
    real_frame = args.real_frame.expanduser().resolve(strict=True)
    output = args.output.expanduser().resolve()
    if output.exists():
        parser.error(f"Refusing to overwrite {output}.")

    import coremltools as ct
    import numpy as np
    import torch
    from PIL import Image
    from ultralytics import YOLOE
    from ultralytics.nn.modules.head import Detect

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".pelagivex-yoloe-export-", dir=output.parent) as temporary:
        work = Path(temporary)
        local_checkpoint = work / checkpoint.name
        shutil.copy2(checkpoint, local_checkpoint)
        source = YOLOE(str(local_checkpoint))
        names = [source.names[index] for index in range(len(source.names))]
        if len(names) != 4585 or not hasattr(source.model.model[-1], "lrpc"):
            raise ValueError("Expected the official 4,585-name prompt-free YOLOE checkpoint.")
        captured = {}
        source.add_callback("on_export_end", lambda exporter: captured.update(model=exporter.model))
        export_arguments = dict(format="coreml", imgsz=args.size, batch=1,
                                nms=False, quantize=args.quantize, dynamic=False,
                                max_det=300, agnostic_nms=True, device="cpu")
        started = time.perf_counter()
        package = Path(source.export(**export_arguments)).resolve()
        export_seconds = time.perf_counter() - started
        reference = captured["model"].cpu().float().eval()
        if not reference.end2end or not all(m.export for m in reference.modules() if isinstance(m, Detect)):
            raise ValueError("Exporter did not select the end-to-end export branch.")
        model = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_ONLY)
        spec = model.get_spec()
        inputs = spec.description.input
        if len(inputs) != 1 or inputs[0].type.WhichOneof("Type") != "imageType":
            raise ValueError("Exactly one Core ML RGB image input is required.")
        image_input = inputs[0]
        if (image_input.type.imageType.width, image_input.type.imageType.height) != (args.size, args.size):
            raise ValueError("Core ML image dimensions differ from export arguments.")
        shapes = {value.name: list(value.type.multiArrayType.shape) for value in spec.description.output}
        contract = dict(schema=2, format="yolo26-e2e-seg", modelName="YOLOE26s PF · 4,585 names",
                        inputName=image_input.name, inputSize=args.size, classNames=names,
                        **inspect_shapes(shapes))
        final = work / "bundle"
        final.mkdir()
        parity_inputs = final / "parity-inputs"
        parity_inputs.mkdir()

        original = Image.open(real_frame).convert("RGB")
        scale = min(args.size / original.width, args.size / original.height)
        resized = original.resize((round(original.width * scale), round(original.height * scale)), Image.Resampling.BILINEAR)
        real_square = Image.new("RGB", (args.size, args.size), (114, 114, 114))
        real_square.paste(resized, ((args.size - resized.width) // 2, (args.size - resized.height) // 2))
        rng = np.random.default_rng(7)
        samples = [("synthetic-gray", np.full((args.size, args.size, 3), 114, np.uint8), True),
                   ("synthetic-random", rng.integers(0, 256, (args.size, args.size, 3), dtype=np.uint8), True),
                   ("real-letterboxed", np.asarray(real_square), False)]
        reports = []
        for sample_name, pixels, synthetic in samples:
            input_path = parity_inputs / f"{sample_name}.png"
            Image.fromarray(pixels).save(input_path)
            tensor = torch.from_numpy(pixels.transpose(2, 0, 1).copy()).float().unsqueeze(0) / 255
            with torch.no_grad():
                expected_predictions, expected_prototypes = reference(tensor)
            started = time.perf_counter()
            actual = model.predict({image_input.name: Image.fromarray(pixels)})
            elapsed = time.perf_counter() - started
            predicted = np.asarray(actual[contract["predictionName"]], dtype=np.float32)
            proto = np.asarray(actual[contract["prototypeName"]], dtype=np.float32)
            expected = expected_predictions.numpy()
            expected_proto = expected_prototypes.numpy()
            if not np.isfinite(predicted).all() or not np.isfinite(proto).all():
                raise ValueError("Core ML produced nonfinite predictions.")
            if list(predicted.shape) != list(expected.shape) or list(proto.shape) != list(expected_proto.shape):
                raise ValueError("Core ML and exported PyTorch tensor shapes disagree.")
            # TopK can reorder nearly equal candidates. Compare high-score rows by
            # geometry, independent of winning label, then explicitly audit labels.
            used = set()
            matches = []
            for row in expected[0][expected[0, :, 4] >= 0.10]:
                costs = np.abs(predicted[0, :, :4] - row[:4]).mean(axis=1) / args.size
                for index in used:
                    costs[index] = np.inf
                index = int(costs.argmin())
                used.add(index)
                candidate = predicted[0, index]
                matches.append(dict(reference_class=int(row[5]), coreml_class=int(round(float(candidate[5]))),
                                    reference_score=float(row[4]), coreml_score=float(candidate[4]),
                                    box_normalized_mean_error=float(costs[index]),
                                    mask_coefficient_mean_error=float(np.abs(candidate[6:] - row[6:]).mean())))
            prototype_error = np.abs(proto - expected_proto)
            report = dict(sample=sample_name, synthetic=synthetic, input_sha256=sha256(input_path),
                          coreml_cpu_only_seconds=elapsed, confident_reference_rows=len(matches), matches=matches,
                          prototype_mean_absolute_error=float(prototype_error.mean()),
                          prototype_max_absolute_error=float(prototype_error.max()),
                          coreml_class_values_integral=bool(np.all(np.abs(predicted[..., 5] - np.round(predicted[..., 5])) < 1e-5)))
            reports.append(report)
            if prototype_error.mean() > 0.10:
                raise ValueError(f"Prototype parity outside smoke limit: {report}")
            for match in matches:
                if match["box_normalized_mean_error"] > 0.02 or abs(match["reference_score"] - match["coreml_score"]) > 0.05:
                    raise ValueError(f"Confident detection parity outside smoke limit: {report}")
                if match["reference_class"] != match["coreml_class"]:
                    raise ValueError(f"Winning class changed during conversion; audit precision before publication: {report}")

        shutil.copytree(package, final / "UniversalSeg.mlpackage")
        (final / "model.json").write_text(json.dumps(contract, indent=2) + "\n")
        provenance = dict(
            checkpoint=checkpoint.name, checkpoint_sha256=sha256(checkpoint),
            checkpoint_source="https://github.com/ultralytics/assets/releases/download/v8.4.0/" + checkpoint.name,
            source_code="https://github.com/ultralytics/ultralytics", license="AGPL-3.0",
            license_policy="https://www.ultralytics.com/license",
            text_model_for_finetuning="yoloe-26s-seg.pt; PF checkpoints do not support training or set_classes directly",
            versions={name: importlib.metadata.version(name) for name in ("torch", "ultralytics", "coremltools", "numpy")},
            platform=platform.platform(), export_arguments=export_arguments, export_seconds=export_seconds,
            actual_output_shapes=shapes, prediction_layout="[batch,row,xyxy_pixels(4)+winning_score+class_index+mask_coefficients]",
            class_score_semantics="Uncalibrated model confidence of the winning class, not a complete calibrated probability distribution.",
            verification="Identical saved RGB square pixels to exported PyTorch branch and Core ML CPU_ONLY; two synthetic inputs and one real RGB frame. Not an accuracy benchmark or a live-camera test.",
            real_frame_source=str(real_frame), real_frame_sha256=sha256(real_frame), parity=reports,
            model_files={str(path.relative_to(final)): sha256(path) for path in sorted((final / "UniversalSeg.mlpackage").rglob("*")) if path.is_file()})
        (final / "export-report.json").write_text(json.dumps(provenance, indent=2) + "\n")
        shutil.move(str(final), str(output))
    print(f"Exported and verified YOLOE end-to-end Core ML bundle: {output}")


if __name__ == "__main__":
    main()

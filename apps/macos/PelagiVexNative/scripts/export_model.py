#!/usr/bin/env python3
"""Export an official YOLO11 segmentation baseline and an inspected Swift contract.

Run on Apple Silicon with the isolated requirements-model.txt environment. This is
not a trainer and does not claim accuracy on any new camera or dataset.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import shutil
import tempfile


def inspect_shapes(outputs: dict[str, list[int]], class_count: int) -> dict:
    prototypes = [(name, shape) for name, shape in outputs.items()
                  if len(shape) == 4 and shape[0] == 1 and 1 <= shape[1] <= 128
                  and 1 <= shape[2] <= 256 and 1 <= shape[3] <= 256]
    if len(prototypes) != 1:
        raise ValueError("Expected exactly one [1,channels,height,width] prototype output.")
    proto_name, proto = prototypes[0]
    predictions = [(name, shape) for name, shape in outputs.items()
                   if len(shape) == 3 and shape[0] == 1
                   and shape[1] == 4 + class_count + proto[1] and 1 <= shape[2] <= 30000]
    if len(predictions) != 1:
        raise ValueError("Expected raw YOLO8/11 [1,4+classes+masks,anchors]; end-to-end YOLO26 is not supported by this adapter.")
    prediction_name, prediction = predictions[0]
    return dict(predictionName=prediction_name, prototypeName=proto_name,
                maskChannels=proto[1], prototypeHeight=proto[2], prototypeWidth=proto[3], predictionCount=prediction[2])


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for part in iter(lambda: stream.read(1024*1024), b""):
            h.update(part)
    return h.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("Model"))
    parser.add_argument("--size", type=int, choices=(384, 512, 640), default=512)
    parser.add_argument("--weights", choices=("yolo11n-seg.pt", "yolo11s-seg.pt"), default="yolo11n-seg.pt")
    parser.add_argument("--acknowledge-model-license", action="store_true")
    args = parser.parse_args()
    if not args.acknowledge_model_license:
        parser.error("Read the upstream model licence before downloading; then supply --acknowledge-model-license.")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("This export-and-prediction verification workflow requires an Apple Silicon Mac.")
    output = args.output.expanduser().resolve()
    if output.exists():
        parser.error(f"Refusing to overwrite {output}. Choose a new --output directory.")
    import coremltools as ct
    import numpy as np
    import torch
    from PIL import Image
    from ultralytics import YOLO

    output.parent.mkdir(parents=True, exist_ok=True)
    # Work in a new sibling directory; publish only after export and smoke parity succeed.
    with tempfile.TemporaryDirectory(prefix=".pelagivex-export-", dir=output.parent) as temporary:
        work = Path(temporary)
        original_cwd = Path.cwd()
        try:
            os.chdir(work)
            source = YOLO(args.weights)  # Official upstream release, not an arbitrary pickle URL.
            names = [source.names[i] for i in range(len(source.names))]
            if len(names) != 80:
                raise ValueError("This baseline expects the official 80-class checkpoint.")
            package = Path(source.export(format="coreml", imgsz=args.size, batch=1,
                                         nms=False, quantize=16, dynamic=False, device="cpu")).resolve()
            model = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_ONLY)
            spec = model.get_spec()
            if len(spec.description.input) != 1:
                raise ValueError("Exactly one image input required.")
            image_input = spec.description.input[0]
            if image_input.type.WhichOneof("Type") != "imageType":
                raise ValueError("The Core ML model must have an image input, not a tensor input.")
            if (image_input.type.imageType.width, image_input.type.imageType.height) != (args.size, args.size):
                raise ValueError("Input image dimensions differ from requested export.")
            shapes = {v.name: list(v.type.multiArrayType.shape) for v in spec.description.output
                      if v.type.WhichOneof("Type") == "multiArrayType"}
            contract = dict(schema=1, format="yolo-v8-11-seg", inputName=image_input.name,
                            inputSize=args.size, classNames=names, **inspect_shapes(shapes, len(names)))
            net = source.model.cpu().float().eval()
            reports = []
            rng = np.random.default_rng(7)
            samples = [np.full((args.size,args.size,3),114,np.uint8),
                       rng.integers(0,256,(args.size,args.size,3),dtype=np.uint8)]
            def tensors(value):
                if isinstance(value, torch.Tensor):
                    yield value
                elif isinstance(value, (tuple, list)):
                    for child in value:
                        yield from tensors(child)
                elif isinstance(value, dict):
                    for child in value.values():
                        yield from tensors(child)
            for index, pixels in enumerate(samples):
                result = model.predict({image_input.name: Image.fromarray(pixels)})
                x = torch.from_numpy(pixels.transpose(2,0,1).copy()).float().unsqueeze(0)/255
                with torch.no_grad():
                    reference = list(tensors(net(x)))
                report = {"sample": index, "synthetic": True}
                for key in ("predictionName", "prototypeName"):
                    name = contract[key]
                    actual = np.asarray(result[name],dtype=np.float32)
                    expected_candidates = [t for t in reference if list(t.shape) == list(actual.shape)]
                    if len(expected_candidates) != 1 or not np.isfinite(actual).all():
                        raise ValueError(f"Output {name}: missing reference, ambiguous shape or non-finite values.")
                    expected = expected_candidates[0].detach().numpy()
                    delta = np.abs(actual-expected)
                    report[key] = {"shape": list(actual.shape), "mean_absolute_error": float(delta.mean()),
                                   "max_absolute_error": float(delta.max())}
                    if key == "predictionName":
                        score_error = float(delta[:,4:4+len(names),:].max())
                        box_error = float(np.quantile(delta[:,:4,:]/args.size,0.95))
                        report["score_max_error"] = score_error
                        report["box_normalized_p95_error"] = box_error
                        if score_error > 0.05 or box_error > 0.02:
                            raise ValueError(f"Core ML conversion parity outside initial smoke limits: {report}")
                    elif float(delta.mean()) > 0.1:
                        raise ValueError("Prototype conversion error outside initial smoke limit.")
                reports.append(report)
            final = work/"bundle"
            final.mkdir()
            shutil.copytree(package, final/"UniversalSeg.mlpackage")
            (final/"model.json").write_text(json.dumps(contract,indent=2)+"\n")
            provenance = {"weights": args.weights, "checkpoint_sha256": sha256(work/args.weights),
                "versions": {p: importlib.metadata.version(p) for p in ("torch","ultralytics","coremltools","numpy")},
                "model_files": {str(p.relative_to(final)): sha256(p) for p in sorted((final/"UniversalSeg.mlpackage").rglob("*")) if p.is_file()},
                "verification": "Two synthetic square inputs; not an accuracy benchmark or camera-preprocessing parity test.",
                "parity": reports,
                "license": "See https://www.ultralytics.com/license and upstream checkpoint terms before redistribution."}
            (final/"export-report.json").write_text(json.dumps(provenance,indent=2)+"\n")
            shutil.move(str(final),str(output))
        finally:
            os.chdir(original_cwd)
    print(f"Model bundle exported and synthetic Core ML/PyTorch smoke parity passed: {output}")


if __name__ == "__main__":
    main()

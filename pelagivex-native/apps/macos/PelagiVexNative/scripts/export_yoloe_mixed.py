#!/usr/bin/env python3
"""Experimental selective-FP16 YOLOE export; never replaces a production bundle.

Preserve the integer-class-index-to-output lineage in FP32 while allowing the
convolutional network and vocabulary projection to use FP16. Optionally preserve
vocabulary linear projections and their downstream calculations too. Numeric
class-index integrity and winning-class rank agreement are distinct checks.
"""
from __future__ import annotations

import argparse
from collections import Counter
import importlib.metadata
import json
from pathlib import Path
import platform
import shutil
import tempfile
import time

from export_yoloe import inspect_shapes, sha256


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--reference-bundle", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--extra-frame", type=Path, action="append", default=[])
    parser.add_argument("--strategy", choices=("index-safe", "classifier-safe"), default="index-safe")
    args = parser.parse_args()
    checkpoint = args.checkpoint.resolve(strict=True)
    baseline = args.reference_bundle.resolve(strict=True)
    output = args.output.resolve()
    if output.exists():
        parser.error(f"Refusing to replace {output}")
    import coremltools as ct
    from coremltools.converters.mil.mil import types
    import numpy as np
    from PIL import Image
    from scipy.optimize import linear_sum_assignment
    import torch
    from ultralytics import YOLOE

    reference_contract = json.loads((baseline / "model.json").read_text())
    size = reference_contract["inputSize"]
    selector_audit = []
    index_memo, argmax_memo, classifier_memo = {}, {}, {}

    def variables(op):
        for value in op.inputs.values():
            yield from value if isinstance(value, (list, tuple)) else [value]

    def has_argmax(op):
        if op is None:
            return False
        if op.name not in argmax_memo:
            argmax_memo[op.name] = op.op_type == "reduce_argmax" or any(has_argmax(v.op) for v in variables(op))
        return argmax_memo[op.name]

    def index_lineage(op):
        if op is None:
            return False
        if op.name not in index_memo:
            seed = (op.op_type == "cast" and types.is_int(op.x.dtype)
                    and op.outputs[0].dtype == types.fp32 and has_argmax(op.x.op))
            index_memo[op.name] = seed or any(index_lineage(v.op) for v in variables(op))
        return index_memo[op.name]

    def classifier_lineage(op):
        if op is None:
            return False
        if op.name not in classifier_memo:
            # The exported prompt-free head's three 4,585-way vocabulary
            # projections are linear ops; record all selected scopes for audit.
            seed = op.op_type in ("linear", "conv") and any("vocab" in v.name for v in variables(op))
            classifier_memo[op.name] = seed or any(classifier_lineage(v.op) for v in variables(op))
        return classifier_memo[op.name]

    def select_fp16(op):
        index_sensitive = index_lineage(op)
        classifier_sensitive = args.strategy == "classifier-safe" and classifier_lineage(op)
        selected = not (index_sensitive or classifier_sensitive)
        selector_audit.append(dict(name=op.name, op_type=op.op_type, fp16=selected,
                                   reason="class-index lineage" if index_sensitive else "vocabulary lineage" if classifier_sensitive else "FP16 eligible",
                                   scopes={str(k): v for k, v in op.scopes.items()},
                                   output_shapes=[list(v.shape) for v in op.outputs],
                                   output_dtypes=[str(v.dtype) for v in op.outputs]))
        return selected

    native_convert = ct.convert

    def mixed_convert(*positional, **keywords):
        keywords["compute_precision"] = ct.transform.FP16ComputePrecision(op_selector=select_fp16)
        return native_convert(*positional, **keywords)

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".pelagivex-mixed-", dir=output.parent) as temporary:
        work = Path(temporary)
        local_checkpoint = work / checkpoint.name
        shutil.copy2(checkpoint, local_checkpoint)
        source = YOLOE(str(local_checkpoint))
        export_arguments = dict(format="coreml", imgsz=size, batch=1, nms=False,
                                quantize=16, dynamic=False, max_det=300,
                                agnostic_nms=True, device="cpu")
        ct.convert = mixed_convert
        try:
            started = time.perf_counter()
            package = Path(source.export(**export_arguments)).resolve()
            export_seconds = time.perf_counter() - started
        finally:
            ct.convert = native_convert
        model = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_ONLY)
        reference_model = ct.models.MLModel(str(baseline / "UniversalSeg.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
        spec = model.get_spec()
        shapes = {v.name: list(v.type.multiArrayType.shape) for v in spec.description.output}
        contract = dict(reference_contract, modelName="YOLOE26s PF Mixed · 4,585 names",
                        modelDescription=f"Experimental selective-FP16 Core ML export ({args.strategy}); class-index output stays FP32.",
                        **inspect_shapes(shapes))
        final = work / "bundle"
        final.mkdir()
        inputs = final / "parity-inputs"
        shutil.copytree(baseline / "parity-inputs", inputs)
        extra_sources = []
        for index, path in enumerate(args.extra_frame):
            path = path.resolve(strict=True)
            image = Image.open(path).convert("RGB")
            scale = min(size / image.width, size / image.height)
            resized = image.resize((round(image.width * scale), round(image.height * scale)), Image.Resampling.BILINEAR)
            pixels = Image.new("RGB", (size, size), (114,114,114))
            pixels.paste(resized, ((size-resized.width)//2, (size-resized.height)//2))
            pixels.save(inputs / f"extra-{index:02}.png")
            extra_sources.append(dict(source=str(path), sha256=sha256(path), input=f"extra-{index:02}.png"))

        reports, failures = [], []
        for path in sorted(inputs.glob("*.png")):
            pixels = Image.open(path).convert("RGB")
            expected = reference_model.predict({reference_contract["inputName"]: pixels})
            actual = model.predict({contract["inputName"]: pixels})
            candidate = np.asarray(actual[contract["predictionName"]], dtype=np.float32)[0]
            reference = np.asarray(expected[reference_contract["predictionName"]], dtype=np.float32)[0]
            selected = reference[reference[:,4] >= .10]
            matches = []
            if len(selected):
                geometry = np.abs(selected[:,None,:4] - candidate[None,:,:4]).mean(axis=2) / size
                coefficients = np.abs(selected[:,None,6:] - candidate[None,:,6:]).mean(axis=2)
                scores = np.abs(selected[:,None,4] - candidate[None,:,4])
                # Assignment does not consult either class index. Coefficients
                # disambiguate nearly coincident boxes from different anchors.
                rows, columns = linear_sum_assignment(geometry + .01*coefficients + .01*scores)
                for row, column in zip(rows, columns):
                    a, e = candidate[column], selected[row]
                    matches.append(dict(reference_class=int(e[5]), mixed_class=int(round(float(a[5]))),
                                        reference_score=float(e[4]), mixed_score=float(a[4]),
                                        box_normalized_mean_error=float(geometry[row,column]),
                                        mask_coefficient_mean_absolute_error=float(coefficients[row,column])))
            proto_error = np.abs(np.asarray(actual[contract["prototypeName"]]) - np.asarray(expected[reference_contract["prototypeName"]]))
            aligned_labels = sum(m["reference_class"] == m["mixed_class"] for m in matches)
            report = dict(sample=path.name, input_sha256=sha256(path), reference_confident_rows=len(matches),
                          matching_class_rows=aligned_labels, mismatching_class_rows=len(matches)-aligned_labels,
                          class_values_integral=bool(np.all(candidate[:,5] == np.round(candidate[:,5]))),
                          prototype_mean_absolute_error=float(proto_error.mean()),
                          prototype_max_absolute_error=float(proto_error.max()), matches=matches)
            reports.append(report)
            if not report["class_values_integral"] or not np.isfinite(candidate).all() or not np.isfinite(proto_error).all():
                failures.append(f"{path.name}: nonintegral classes or nonfinite tensors")
            print(f"{path.name}: label agreement {aligned_labels}/{len(matches)}, prototype MAE {proto_error.mean():.6g}", flush=True)

        # A separate forced-logit probe tests numeric index preservation even
        # when CNN quantization changes a near-tied vocabulary rank.
        class IndexProbe(torch.nn.Module):
            def forward(self, scores):
                confidence, labels = scores.max(dim=-1)
                label = labels[...,None].float()
                return torch.cat((confidence[...,None], label), dim=-1)
        probe_ids = [2049, 3123, 3927, 3963, 4353, 4583]
        logits = np.zeros((1, len(probe_ids), 4585), np.float32)
        for index, class_id in enumerate(probe_ids):
            logits[0,index,class_id] = 1
        traced = torch.jit.trace(IndexProbe().eval(), torch.from_numpy(logits))
        probe_model = native_convert(traced, inputs=[ct.TensorType(name="scores", shape=logits.shape)],
                                     compute_precision=ct.transform.FP16ComputePrecision(op_selector=select_fp16),
                                     compute_units=ct.ComputeUnit.CPU_ONLY, convert_to="mlprogram")
        probe_model.save(str(final / "ClassIndexProbe.mlpackage"))
        probe_result = next(iter(probe_model.predict({"scores": logits}).values()))
        probe_actual = [int(v) for v in np.asarray(probe_result)[0,:,1]]
        if probe_actual != probe_ids:
            failures.append(f"Forced numeric index probe failed: {probe_actual}")
        if failures:
            raise ValueError(f"Unsafe mixed export: {failures}")

        shutil.copytree(package, final / "UniversalSeg.mlpackage")
        (final / "model.json").write_text(json.dumps(contract, indent=2) + "\n")
        (final / "precision-selector.json").write_text(json.dumps(selector_audit, indent=2, default=str) + "\n")
        block = next(iter(spec.mlProgram.functions["main"].block_specializations.values()))
        typed_operations = Counter((op.type, str(value.type.tensorType.dataType))
                                   for op in block.operations for value in op.outputs)
        proof = dict(strategy=args.strategy, export_arguments=export_arguments, export_seconds=export_seconds,
                     artifact_size_bytes=sum(p.stat().st_size for p in (final / "UniversalSeg.mlpackage").rglob("*") if p.is_file()),
                     checkpoint=checkpoint.name, checkpoint_sha256=sha256(checkpoint),
                     source="https://github.com/ultralytics/assets/releases/download/v8.4.0/"+checkpoint.name,
                     license="AGPL-3.0; https://www.ultralytics.com/license", platform=platform.platform(),
                     versions={v: importlib.metadata.version(v) for v in ("torch","ultralytics","coremltools","numpy","scipy")},
                     precision_rationale="FP16 features and vocabulary by default; integer-derived class-label cast and all its descendants stay FP32. classifier-safe additionally pins vocabulary linear projections and descendants.",
                     apple_precision_docs="https://apple.github.io/coremltools/docs-guides/source/typed-execution.html",
                     apple_selector_api="https://apple.github.io/coremltools/source/coremltools.converters.convert.html",
                     selector_fp32_operations=[v for v in selector_audit if not v["fp16"]],
                     typed_operation_counts={f"{key[0]}:{key[1]}": value for key,value in typed_operations.items()},
                     forced_numeric_class_probe=dict(expected=probe_ids, actual=probe_actual, passed=probe_ids==probe_actual),
                     reference_bundle=str(baseline), verification_scope="CPU_ONLY mixed Core ML versus previously verified FP32 Core ML, identical saved square RGB. Numeric class encoding and winning-label rank agreement reported separately. Not detection accuracy.",
                     extra_sources=extra_sources, parity=reports,
                     high_confidence_label_agreement=dict(matched=sum(r["matching_class_rows"] for r in reports), total=sum(r["reference_confident_rows"] for r in reports)),
                     model_files={str(p.relative_to(final)): sha256(p) for p in sorted((final/"UniversalSeg.mlpackage").rglob("*")) if p.is_file()})
        (final / "export-report.json").write_text(json.dumps(proof, indent=2, default=str)+"\n")
        shutil.move(str(final), str(output))
    print(f"Experimental mixed bundle saved (review rank changes before deployment): {output}")


if __name__ == "__main__":
    main()

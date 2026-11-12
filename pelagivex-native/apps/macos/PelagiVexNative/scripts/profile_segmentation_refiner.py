#!/usr/bin/env python3
"""Profile reference/optimized SAM paths on saved real RGB-D frames.

Mask overlap is against the existing implementation, not ground truth. Mixed
precision is an experiment only; the worker's default remains float32.
"""
import argparse
import base64
from contextlib import nullcontext
import io
import json
from pathlib import Path
import statistics
import time


def decode_map(payload):
    import numpy as np
    from PIL import Image
    return np.asarray(Image.open(io.BytesIO(base64.b64decode(payload["data"]))))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[5])
    parser.add_argument("--runs", type=int, default=4)
    parser.add_argument("--autocast", action="store_true")
    parser.add_argument("--stress-objects", type=int, default=0)
    args = parser.parse_args()
    if args.runs < 1 or not 0 <= args.stress_objects <= 100:
        parser.error("Use at least one measured run and stress-objects in [0,100].")
    import numpy as np
    from PIL import Image
    import torch
    from segmentation_refiner import SegmentationRefiner
    torch.set_num_threads(2)
    root = args.root.resolve()
    destination = root / ".cache/general-vision/sam-profile"
    destination.mkdir(parents=True, exist_ok=True)
    refiner = SegmentationRefiner(root)
    cases = []
    for name, folder, target in [("chairs", "bonn-chairs-near", 0), ("crowd", "bonn-crowd3", 6.2)]:
        base = root / ".cache/pair-study" / folder
        manifest = json.loads((base / "manifest.json").read_text())
        trace = json.loads((base / "trace.json").read_text())
        index = min(range(len(trace["frames"])), key=lambda i: abs(trace["frames"][i]["time"] - target))
        frame = trace["frames"][index]
        source = manifest["frames"][index]
        if source["time"] != frame["time"]:
            raise ValueError("Manifest and trace frame times differ.")
        image = np.asarray(Image.open(base / source["image"]).convert("RGB")).copy()
        detections = [{"label": entry["name"], "confidence": entry["score"], "box": entry["box"]}
                      for entry in frame["detections"]]
        cases.append((name, image, detections, str((base / source["image"]).relative_to(root))))
    if args.stress_objects:
        name, image, detections, source = cases[-1]
        # Deliberately repeated box prompts and resized public RGB for decoder/load
        # stress, NOT twenty-five independently annotated objects or accuracy data.
        expanded = [dict(detections[index % len(detections)]) for index in range(args.stress_objects)]
        image = np.asarray(Image.fromarray(image).resize((1280, 720), Image.Resampling.LANCZOS)).copy()
        cases.append((f"synthetic-load-{args.stress_objects}", image, expanded,
                      source + " (resized to1280x720 and repeated box prompts; synthetic load only)"))
    records = []
    for name, image, detections, source in cases:
        baseline, baseline_scores = refiner.refine(image, detections, reference=True)
        baseline_map = decode_map(baseline)
        modes = ["reference", "selected-cpu-compose", "selected-device-compose"]
        if args.autocast and refiner.device == "mps":
            modes.append("autocast16-experiment")
        for mode in modes:
            samples = []
            for run in range(args.runs + 2):
                try:
                    context = torch.autocast("mps", dtype=torch.float16) if mode.startswith("autocast") else nullcontext()
                    started = time.perf_counter()
                    with context:
                        payload, scores = refiner.refine(image, detections, reference=mode == "reference",
                                                         compose_on_device=mode != "selected-cpu-compose")
                    elapsed = time.perf_counter() - started
                    actual = decode_map(payload)
                    per_instance_iou = []
                    for index in range(1, len(detections)+1):
                        first, second = baseline_map == index, actual == index
                        union = int((first | second).sum())
                        per_instance_iou.append(float((first & second).sum()) / union if union else 1.0)
                    sample = {
                        "run": run, "warmup": run < 2, "wallSeconds": elapsed, **refiner.last_timings,
                        "differentPixelsFromReference": int((actual != baseline_map).sum()),
                        "instanceIoUWithReference": per_instance_iou,
                        "maskScores": scores,
                    }
                    if run >= 2:
                        samples.append(sample)
                    if run == args.runs + 1:
                        (destination / f"{name}-{mode}.png").write_bytes(base64.b64decode(payload["data"]))
                except Exception as error:
                    samples.append({"error": repr(error), "run": run})
                    break
            valid = [sample for sample in samples if "wallSeconds" in sample]
            median = statistics.median(sample["wallSeconds"] for sample in valid) if valid else None
            records.append({
                "case": name, "source": source, "instances": len(detections), "mode": mode,
                "medianSeconds": median, "reciprocalMedianHz": 1/median if median else None,
                "samples": samples,
            })
            print(name, mode, len(detections), median, flush=True)
    report = {
        "model": refiner.model, "device": refiner.device, "torch": torch.__version__,
        "loadSeconds": refiner.load_seconds, "records": records,
        "qualityScope": "Instance-map overlap with existing float32 multimask selection; not annotation accuracy.",
        "notMeasured": ["ground-truth segmentation accuracy", "detection recall", "sustained camera throughput"],
        "default": "selectedAndComposedOnDevice float32; autocast is profiling-only",
    }
    (destination / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(destination / "results.json")


if __name__ == "__main__":
    main()

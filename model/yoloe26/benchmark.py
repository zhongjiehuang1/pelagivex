#!/usr/bin/env python3
"""Recorded-frame smoke timing. No ground-truth accuracy is measured."""
import argparse
import hashlib
import json
from pathlib import Path
import time


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, default=root / ".cache/yoloe26/yoloe-26s-seg-pf.pt")
    parser.add_argument("--output", type=Path, default=root / ".cache/yoloe26/mps-benchmark.json")
    parser.add_argument("--runs", type=int, default=4)
    parser.add_argument("--confidence", type=float, default=0.2)
    parser.add_argument("images", nargs="*", type=Path)
    args = parser.parse_args()
    if args.runs < 1 or not 0 <= args.confidence <= 1:
        parser.error("Use at least one run and confidence in [0,1].")
    images = args.images or [
        root / ".cache/pair-study/bonn-chairs-near/rgb/0000.png",
        root / ".cache/pair-study/bonn-crowd3/rgb/0185.png",
    ]
    import torch
    import ultralytics
    from ultralytics import YOLOE
    torch.set_num_threads(2)
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    started = time.perf_counter()
    model = YOLOE(args.checkpoint)
    load_seconds = time.perf_counter() - started
    records = []
    for image in images:
        if not image.is_file():
            raise FileNotFoundError(image)
        for run in range(args.runs):
            started = time.perf_counter()
            result = model.predict(str(image), imgsz=640, device=device, conf=args.confidence,
                                   iou=0.5, max_det=100, rect=False, verbose=False)[0]
            if device == "mps":
                torch.mps.synchronize()
            elapsed = time.perf_counter() - started
            detections = [
                {"classID": int(cls), "name": result.names[int(cls)],
                 "confidence": float(score), "box": box.tolist()}
                for box, score, cls in zip(result.boxes.xyxy.cpu(), result.boxes.conf.cpu(), result.boxes.cls.cpu())
            ]
            records.append({
                "image": str(image), "run": run, "roundtripSeconds": elapsed,
                "speedMS": result.speed, "detections": detections,
                "maskShape": None if result.masks is None else list(result.masks.data.shape),
            })
    report = {
        "checkpoint": str(args.checkpoint), "sha256": hashlib.sha256(args.checkpoint.read_bytes()).hexdigest(),
        "loadSeconds": load_seconds, "device": device, "ultralytics": ultralytics.__version__,
        "torch": torch.__version__, "vocabularyCount": len(model.names), "records": records,
        "note": "Repeated public recorded frames; no accuracy claim. Native Core ML timing is separate.",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(args.output)


if __name__ == "__main__":
    main()

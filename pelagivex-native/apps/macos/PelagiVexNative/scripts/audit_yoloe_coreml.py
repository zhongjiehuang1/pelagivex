#!/usr/bin/env python3
"""Audit native compute-unit label parity and time saved square RGB predictions.

Run after export_yoloe.py. Timing excludes capture, resizing, decoding, tracking
and rendering; it must not be presented as live application FPS.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import platform
import time


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--repetitions", type=int, default=5)
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error("--repetitions must be positive.")
    import coremltools as ct
    import numpy as np
    from PIL import Image

    bundle = args.bundle.expanduser().resolve(strict=True)
    contract = json.loads((bundle / "model.json").read_text())
    cpu = ct.models.MLModel(str(bundle / "UniversalSeg.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
    accelerated = ct.models.MLModel(str(bundle / "UniversalSeg.mlpackage"), compute_units=ct.ComputeUnit.ALL)
    reports = []
    for path in sorted((bundle / "parity-inputs").glob("*.png")):
        image = Image.open(path).convert("RGB")
        expected = cpu.predict({contract["inputName"]: image})
        started = time.perf_counter()
        actual = accelerated.predict({contract["inputName"]: image})
        first_seconds = time.perf_counter() - started
        candidates = np.asarray(actual[contract["predictionName"]])
        reference = np.asarray(expected[contract["predictionName"]])
        used, matches = set(), []
        for row in reference[0][reference[0, :, 4] >= .10]:
            costs = np.abs(candidates[0, :, :4] - row[:4]).mean(axis=1) / contract["inputSize"]
            for index in used:
                costs[index] = np.inf
            index = int(costs.argmin())
            used.add(index)
            candidate = candidates[0, index]
            match = dict(cpu_class=int(row[5]), all_class=int(round(float(candidate[5]))),
                         box_normalized_mean_error=float(costs[index]),
                         score_error=float(abs(row[4] - candidate[4])))
            matches.append(match)
            if match["cpu_class"] != match["all_class"] or match["box_normalized_mean_error"] > .02 or match["score_error"] > .05:
                raise ValueError(f"ALL/CPU_ONLY parity failed on {path.name}: {match}")
        times = []
        for _ in range(args.repetitions):
            started = time.perf_counter()
            accelerated.predict({contract["inputName"]: image})
            times.append(time.perf_counter() - started)
        report = dict(sample=path.name, first_call_seconds=first_seconds,
                      warm_seconds=times, warm_median_seconds=float(np.median(times)), matches=matches,
                      prototype_mean_absolute_error=float(np.abs(actual[contract["prototypeName"]] - expected[contract["prototypeName"]]).mean()))
        reports.append(report)
        print(f"{path.name}: {report['warm_median_seconds']*1000:.2f} ms; {len(matches)} confident labels agree", flush=True)
    result = dict(model=contract.get("modelName"), platform=platform.platform(),
                  compute_units="ALL compared with verified CPU_ONLY conversion",
                  timing_scope="CoreML Python MLModel.predict only; saved square RGB inputs; excludes capture, letterbox, decode, tracking, render",
                  warmups=1, timed_repetitions=args.repetitions, reports=reports)
    (bundle / "compute-unit-audit.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()

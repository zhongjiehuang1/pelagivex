#!/usr/bin/env python3
"""Audit cached per-frame depth opportunities, using future truth only offline.

Run from any directory with Python 3.10+. The default study directory is the
checkout's .cache/pair-study. This reads existing predictions and never invokes
a model or presents an oracle as a deployable policy.
"""

import argparse
import bisect
from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import statistics


MAX_GAP = 0.5
DIRECTIONAL = {"aCloser", "bCloser"}
CASES = {
    "tum-10hz-crossing1": ("trace-10fps.json", 1, 2, None),
    "tum-10hz-crossing2": ("trace-10fps.json", 67, 92, None),
    "tum-5hz-crossing1": ("trace.json", 1, 2, None),
    "tum-5hz-crossing2": ("trace.json", 81, 106, None),
    "bonn-chairs-near": ("bonn-chairs-near/trace.json", 2, 1,
                         "bonn-chairs-near/independent.json"),
    "bonn-chairs-far": ("bonn-chairs-far/trace.json", 1, 2,
                        "bonn-chairs-far/independent.json"),
    "bonn-crowd3": ("bonn-crowd3/trace.json", 27, 1,
                    "bonn-crowd3/independent.json"),
}


@dataclass(frozen=True)
class Frame:
    time: float
    visible: bool
    reference: str | None
    prediction: str | None
    worker_seconds: float | None


def positive(value):
    if isinstance(value, (int, float)) and math.isfinite(value) and value > 0:
        return value
    return None


def ordering(depth_a, depth_b):
    if positive(depth_a) is None or positive(depth_b) is None:
        return None
    tolerance = max(0.05, 0.05 * min(depth_a, depth_b))
    if abs(depth_a - depth_b) <= tolerance + 1e-12:
        return "tooClose"
    return "aCloser" if depth_a < depth_b else "bCloser"


def read_json(path):
    data = path.read_bytes()
    return json.loads(data), hashlib.sha256(data).hexdigest()


def load_frames(root, specification):
    trace_path, a, b, label_path = specification
    trace, trace_hash = read_json(root / trace_path)
    hashes = {trace_path: trace_hash}
    labels = None
    if label_path is not None:
        sidecar, hashes[label_path] = read_json(root / label_path)
        if (sidecar["trackA"], sidecar["trackB"]) != (a, b):
            raise ValueError(f"{label_path} has different selected IDs")
        labels = {frame["time"]: frame for frame in sidecar["frames"]}
        if len(labels) != len(sidecar["frames"]):
            raise ValueError(f"{label_path} contains duplicate times")

    frames = []
    for source in trace["frames"]:
        time = source["time"]
        if not math.isfinite(time) or time < 0 or (frames and time <= frames[-1].time):
            raise ValueError(f"{trace_path} needs increasing finite nonnegative times")
        selected = [item for item in source["detections"] if item["id"] in (a, b)]
        tracks = {item["id"]: item for item in selected}
        if len(tracks) != len(selected):
            raise ValueError(f"{trace_path} contains duplicate selected IDs")
        visible = a in tracks and b in tracks
        prediction = reference = None
        if visible:
            first, second = tracks[a], tracks[b]
            prediction = ordering(first.get("depth"), second.get("depth"))
            if labels is None:
                reference = ordering(first.get("reference"), second.get("reference"))
            else:
                label = labels.get(time, {})
                reference = ordering(label.get("depthA"), label.get("depthB"))
        frames.append(Frame(time, visible, reference, prediction,
                            positive(source.get("depthSeconds"))))
    if len(frames) < 2:
        raise ValueError(f"{trace_path} needs at least two frames")
    if labels is not None and not set(labels).issubset({frame.time for frame in frames}):
        raise ValueError(f"{label_path} has times absent from the trace")
    return frames, hashes


def reversal_indices(frames):
    """Match PairReplay's two-adjacent-reference-frame event definition."""
    previous = None
    events = []
    for index, frame in enumerate(frames[:-1]):
        if index > 0 and frame.time - frames[index - 1].time > MAX_GAP:
            previous = None
        if frame.reference is None:
            previous = None
            continue
        following = frames[index + 1]
        if (frame.reference not in DIRECTIONAL or following.reference != frame.reference
                or following.time - frame.time > MAX_GAP):
            continue
        if previous is not None and frame.reference != previous:
            events.append(index)
        previous = frame.reference
    return events


def horizon(frames, start, strict):
    """Return the exclusive end of a reference episode or original-ID track."""
    direction = frames[start].reference
    end = start
    reason = "traceEnd"
    while end < len(frames):
        frame = frames[end]
        if end > start and frame.time - frames[end - 1].time > MAX_GAP:
            reason = "captureGap"
            break
        if not frame.visible:
            reason = "selectedTrackLost"
            break
        if strict and frame.reference != direction:
            reason = "referenceMissing" if frame.reference is None else "referenceChangedOrTooClose"
            break
        if strict is False and frame.reference in DIRECTIONAL and frame.reference != direction:
            reason = "oppositeReference"
            break
        end += 1
    return end, reason


def opportunity(frames, times, start, end, fallback):
    direction = frames[start].reference
    correct = [index for index in range(start, end)
               if frames[index].reference == direction and frames[index].prediction == direction]
    first_available = None
    first_available_source = None
    first_two = None
    for index in correct:
        source = frames[index]
        finish = source.time + (source.worker_seconds or fallback)
        arrival = bisect.bisect_left(times, finish)
        if (arrival < end and frames[arrival].reference == direction
                and (first_available is None or arrival < first_available)):
            first_available = arrival
            first_available_source = index
        if (first_two is None and index + 1 < end
                and frames[index + 1].reference == direction
                and frames[index + 1].prediction == direction):
            first_two = index + 1
    start_time = frames[start].time
    return {
        "source_frames": end - start,
        "directional_reference_frames": sum(frames[index].reference == direction
                                            for index in range(start, end)),
        "correct_model_source_frames": len(correct),
        "first_correct_source_time": frames[correct[0]].time if correct else None,
        "first_correct_source_delay_seconds": frames[correct[0]].time - start_time if correct else None,
        "optimistic_available_time": times[first_available] if first_available is not None else None,
        "optimistic_available_delay_seconds": times[first_available] - start_time if first_available is not None else None,
        "optimistic_request_time": times[first_available_source] if first_available_source is not None else None,
        "first_two_consecutive_correct_source_time": times[first_two] if first_two is not None else None,
    }


def audit(name, frames):
    times = [frame.time for frame in frames]
    durations = [frame.worker_seconds for frame in frames if frame.worker_seconds is not None]
    if not durations:
        raise ValueError(f"{name} has no measured worker durations")
    fallback = statistics.median(durations)
    totals = dict.fromkeys(("visible", "scored", "directionalReference", "modelCorrect",
                            "modelTooClose", "modelOpposite", "modelMissing"), 0.0)
    for frame, following in zip(frames, frames[1:]):
        duration = following.time - frame.time
        if duration > MAX_GAP or not frame.visible:
            continue
        totals["visible"] += duration
        if frame.reference is None:
            continue
        totals["scored"] += duration
        if frame.reference not in DIRECTIONAL:
            continue
        totals["directionalReference"] += duration
        if frame.prediction == frame.reference:
            totals["modelCorrect"] += duration
        elif frame.prediction == "tooClose":
            totals["modelTooClose"] += duration
        elif frame.prediction is None:
            totals["modelMissing"] += duration
        else:
            totals["modelOpposite"] += duration

    events = []
    for start in reversal_indices(frames):
        event = {"time": times[start], "new_direction": frames[start].reference}
        for key, strict in (("strict_episode", True), ("until_opposite_or_track_loss", False),
                            ("original_track_horizon", None)):
            end, reason = horizon(frames, start, strict)
            end_time = times[end] if end < len(frames) else times[-1]
            result = {"end_time": end_time, "end_reason": reason,
                      "horizon_seconds": end_time - times[start]}
            if strict is not None:
                result.update(opportunity(frames, times, start, end, fallback))
            event[key] = result
        events.append(event)
    directional = totals["directionalReference"]
    return {
        "name": name,
        "trace_frames": len(frames),
        "co_visible_frames": sum(frame.visible for frame in frames),
        "time_weighted_seconds": totals,
        "model_correct_fraction_of_directional_reference_time": totals["modelCorrect"] / directional if directional else None,
        "cached_trace_worker_seconds": sum(durations),
        "events": events,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--study", type=Path,
                        default=Path(__file__).resolve().parents[1] / ".cache/pair-study")
    parser.add_argument("--case", action="append", choices=CASES,
                        help="Audit selected cases. Repeat to include multiple cases.")
    arguments = parser.parse_args()
    results = []
    hashes = {}
    for name in arguments.case or CASES:
        frames, inputs = load_frames(arguments.study, CASES[name])
        result = audit(name, frames)
        result["reference_kind"] = "independentRgbLandmarkSensorDepth" if CASES[name][3] else "sharedPredictedMaskSensorDepth"
        result["track_a"], result["track_b"] = CASES[name][1:3]
        results.append(result)
        hashes.update(inputs)
    events = [event for case in results for event in case["events"]]
    summary = {
        "cases": len(results),
        "reference_reversals": len(events),
        "events_with_no_correct_source_in_strict_episode": sum(
            event["strict_episode"]["correct_model_source_frames"] == 0 for event in events),
        "events_with_optimistic_available_correct_source_in_strict_episode": sum(
            event["strict_episode"]["optimistic_available_time"] is not None for event in events),
    }
    output = {
        "method": {
            "type": "offline ex-post frame oracle audit",
            "tolerance": "max(0.05 metre, 5% of nearer depth), inclusive",
            "reference_event": "two adjacent frames in new direction after confirmed opposite, matching PairReplay",
            "strict_episode": "reference remains in the new direction and original IDs remain visible",
            "extended_episode": "allows near-tie or missing reference until first opposite reference, original-ID loss, capture gap or trace end",
            "optimistic_availability": "one future-selected request, no budget or geometry invalidation, measured worker delay rounded to next sampled frame, arrival reference must still agree",
            "limitations": "No causal scheduling or simultaneous dense inference is simulated. Correct source and future truth are selected with hindsight. Two consecutive source predictions are a stability diagnostic and require two observations. TUM rates reuse one recording and cases are not independent trials. Cached trace worker totals include all detected objects and must not be summed across reused traces.",
        },
        "input_sha256": hashes,
        "descriptive_summary_without_independent_trial_claim": summary,
        "cases": results,
    }
    print(json.dumps(output, indent=2, sort_keys=True, allow_nan=False))


if __name__ == "__main__":
    main()

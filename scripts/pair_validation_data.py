#!/usr/bin/env python3
"""Prepare synchronized held-out RGB-D inputs and RGB-only annotation sidecars."""

import argparse
import bisect
import hashlib
import io
import json
import zipfile
from decimal import Decimal
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


# Windows were selected by viewing source RGB contact sheets before replay.
# Times are relative to the first RGB exposure in each source recording.
DATASETS = {
    "chairs-near": (
        "chairs", "Bonn RGB-D Rigid Multi-Body, Chairs (Stückler and Behnke, BMVC 2013)",
        0.0, 16.5,
    ),
    "chairs-far": (
        "chairs", "Bonn RGB-D Rigid Multi-Body, Chairs (Stückler and Behnke, BMVC 2013)",
        20.2, 34.3,
    ),
    "crowd3": (
        "rgbd_bonn_crowd3", "Bonn RGB-D Dynamic Dataset, Crowd3 (Palazzolo et al., IROS 2019)",
        0.0, 11.5,
    ),
}
DEPTH_SCALE = 5000
TILE_SIZE = (240, 180)
PATCH_RADIUS = 5
MIN_VALID_FRACTION = 0.8
MAX_IQR_METRES = 0.12


def load_json(path):
    return json.loads(path.read_text())


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def timestamp_index(archive, filename):
    rows = []
    for line in archive.read(filename).decode().splitlines():
        fields = line.split()
        if not fields or fields[0].startswith("#"):
            continue
        stamp, path = fields
        rows.append((Decimal(stamp), path))
    return sorted(rows)


def nearest_index(times, target):
    pos = bisect.bisect_left(times, target)
    return min(range(max(0, pos - 1), min(len(times), pos + 1)),
               key=lambda index: abs(times[index] - target))


def prepare(dataset, archive_path, output):
    prefix, source, start, end = DATASETS[dataset]
    output.mkdir(parents=True, exist_ok=True)
    for folder in ("rgb", "depth"):
        (output / folder).mkdir(exist_ok=True)
    frames = []
    with zipfile.ZipFile(archive_path) as archive:
        rgb = timestamp_index(archive, f"{prefix}/rgb.txt")
        depth = timestamp_index(archive, f"{prefix}/depth.txt")
        rgb_times, depth_times = ([t for t, _ in values] for values in (rgb, depth))
        first = rgb_times[0]
        selected = sorted({
            nearest_index(rgb_times, first + Decimal(str(start)) + Decimal(step) / 10)
            for step in range(round((end - start) * 10) + 1)
        })
        for index in selected:
            stamp, rgb_path = rgb[index]
            dep_stamp, dep_path = depth[nearest_index(depth_times, stamp)]
            skew_ms = float((dep_stamp - stamp) * 1000)
            if abs(skew_ms) > 20:
                continue
            image_path, depth_path = f"rgb/{index:04}.png", f"depth/{index:04}.png"
            rgb_bytes = archive.read(f"{prefix}/{rgb_path}")
            depth_bytes = archive.read(f"{prefix}/{dep_path}")
            with Image.open(io.BytesIO(depth_bytes)) as depth_image:
                if depth_image.mode not in {"I;16", "I"}:
                    raise ValueError(f"{dep_path} is not a raw 16-bit depth image")
            (output / image_path).write_bytes(rgb_bytes)
            (output / depth_path).write_bytes(depth_bytes)
            frames.append({
                "time": float(stamp - first), "image": image_path, "depth": depth_path,
                "rgbTime": str(stamp), "depthTime": str(dep_stamp), "syncSkewMs": skew_ms,
                "sourceRgb": rgb_path, "sourceDepth": dep_path, "sourceIndex": index,
            })
    if not frames:
        raise ValueError("No synchronized RGB-D frames")
    with archive_path.open("rb") as archive_file:
        digest = hashlib.file_digest(archive_file, "sha256").hexdigest()
    save_json(output / "manifest.json", {
        "source": source, "depthUnitsPerMetre": DEPTH_SCALE, "archiveSHA256": digest,
        "frames": frames,
    })
    print(f"{len(frames)} pairs spanning {frames[0]['time']}–{frames[-1]['time']} s, "
          f"max |RGB/depth skew| {max(abs(f['syncSkewMs']) for f in frames):.3f} ms, "
          f"source archive SHA-256 {digest}")


def contact_sheets(manifest_path, stride, name, annotations=None, tracks=None):
    root = manifest_path.parent
    frames = load_json(manifest_path)["frames"][::stride]
    width, height = TILE_SIZE
    offset = 20
    columns, batch_size = 5, 20
    if tracks:
        detections = {frame["time"]: frame["detections"] for frame in tracks["frames"]}
    else:
        detections = {}
    for start in range(0, len(frames), batch_size):
        batch = frames[start:start + batch_size]
        canvas = Image.new("RGB", (columns * width, ((len(batch) + columns - 1) // columns)
                                   * (height + offset)), "white")
        draw = ImageDraw.Draw(canvas)
        for i, frame in enumerate(batch):
            ox, oy = i % columns * width, i // columns * (height + offset)
            with Image.open(root / frame["image"]) as photo:
                canvas.paste(photo.resize(TILE_SIZE, Image.Resampling.LANCZOS), (ox, oy))
            source_index = frame["sourceIndex"]
            draw.text((ox + 3, oy + height + 2), f'{frame["time"]:6.3f}s #{source_index}',
                      fill="black")
            if annotations is not None:
                pair = annotations.get(source_index)
                for point, color in zip(pair or (None, None), ("#ff4444", "#44ffff")):
                    if point is None:
                        continue
                    x, y = point
                    draw.ellipse((ox + x - 3, oy + y - 3, ox + x + 3, oy + y + 3),
                                 outline=color, width=2)
            if tracks is not None:
                for detection in detections.get(frame["time"], []):
                    if detection["name"] not in {"person", "chair"}:
                        continue
                    x1, y1, x2, y2 = detection["box"]
                    box = (ox + int(x1 * width), oy + int(y1 * height),
                           ox + int(x2 * width), oy + int(y2 * height))
                    label = str(detection["id"])
                    draw.rectangle(box, outline="#00ff88")
                    draw.text((box[0] + 2, box[1] + 1), label, fill="#00ff88", stroke_width=1,
                              stroke_fill="black")
        canvas.save(root / f"{name}-{start:03}.jpg", quality=95)


def interpolate_points(indices, anchors):
    keys = sorted(anchors)
    for index in indices:
        if index in anchors:
            yield anchors[index]
            continue
        pos = bisect.bisect_left(keys, index)
        if pos == 0 or pos == len(keys) or keys[pos] - keys[pos - 1] > 19:
            yield (None, None)
            continue
        before, after = keys[pos - 1:pos + 1]
        weight = (index - before) / (after - before)
        yield [
            None if a is None or b is None else [round(x + weight * (y - x)) for x, y in zip(a, b)]
            for a, b in zip(anchors[before], anchors[after])
        ]


def read_patch(raw, point):
    if point is None:
        return None
    height, width = raw.shape
    x = round(point[0] * width / TILE_SIZE[0])
    y = round(point[1] * height / TILE_SIZE[1])
    radius = PATCH_RADIUS
    if not radius <= x < width - radius or not radius <= y < height - radius:
        return {"pixel": [x, y], "depthMetres": None, "reason": "edge"}
    patch = raw[y - radius:y + radius + 1, x - radius:x + radius + 1]
    valid = patch[patch > 0]
    valid_fraction = valid.size / patch.size
    if valid_fraction < MIN_VALID_FRACTION:
        return {"pixel": [x, y], "depthMetres": None,
                "validFraction": valid_fraction, "reason": "sparse sensor depth"}
    quartiles = np.percentile(valid, [25, 50, 75]) / DEPTH_SCALE
    iqr = float(quartiles[2] - quartiles[0])
    return {"pixel": [x, y], "depthMetres": float(quartiles[1]) if iqr <= MAX_IQR_METRES else None,
            "validFraction": valid_fraction, "iqrMetres": iqr,
            **({"reason": "mixed surfaces"} if iqr > MAX_IQR_METRES else {})}


def reference(manifest_path, anchor_path, output_path):
    manifest = load_json(manifest_path)
    annotation = load_json(anchor_path)
    frames = manifest["frames"]
    indices = [frame["sourceIndex"] for frame in frames]
    points = dict(zip(indices, interpolate_points(
        indices, {int(key): value for key, value in annotation["anchors"].items()}
    )))
    output = []
    for frame in frames:
        with Image.open(manifest_path.parent / frame["depth"]) as depth:
            raw = np.asarray(depth)
        index = frame["sourceIndex"]
        a, b = [read_patch(raw, point) for point in points[index]]
        output.append({
            "time": frame["time"], "depthA": a and a["depthMetres"],
            "depthB": b and b["depthMetres"], "pointA": a, "pointB": b,
            "sourceIndex": index, "sourceRgb": frame["sourceRgb"],
            "sourceDepth": frame["sourceDepth"], "syncSkewMs": frame["syncSkewMs"],
        })
    save_json(output_path, {
        "source": (f'{manifest["source"]}, synchronized sensor depth in independent RGB-only '
                   f'landmarks for {annotation["subjectA"]} and {annotation["subjectB"]}'),
        "trackA": annotation["trackA"], "trackB": annotation["trackB"], "frames": output,
    })
    contact_sheets(manifest_path, 1, output_path.stem, annotations=points)
    valid = sum(row["depthA"] is not None and row["depthB"] is not None for row in output)
    print(f"{valid}/{len(frames)} frames have valid sensor patches on both subjects")


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    sub = cli.add_subparsers(dest="command", required=True)
    prepare_cli = sub.add_parser("prepare")
    prepare_cli.add_argument("dataset", choices=DATASETS)
    prepare_cli.add_argument("archive", type=Path)
    prepare_cli.add_argument("output", type=Path)
    contact_cli = sub.add_parser("contact")
    contact_cli.add_argument("manifest", type=Path)
    contact_cli.add_argument("--stride", type=int, default=1)
    contact_cli.add_argument("--trace", type=Path)
    reference_cli = sub.add_parser("reference")
    reference_cli.add_argument("manifest", type=Path)
    reference_cli.add_argument("anchors", type=Path)
    reference_cli.add_argument("output", type=Path)
    args = cli.parse_args()
    if args.command == "prepare":
        prepare(args.dataset, args.archive, args.output)
    elif args.command == "contact":
        trace = load_json(args.trace) if args.trace else None
        contact_sheets(args.manifest, args.stride, "tracks" if trace else "contact", tracks=trace)
    else:
        reference(args.manifest, args.anchors, args.output)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Extract the development RGB-D inputs from the Voxel51 TUM MCAP."""

import argparse
import bisect
import io
import json
import subprocess
from pathlib import Path

import imageio_ffmpeg
import numpy as np
from PIL import Image, ImageDraw
from mcap.reader import make_reader

WIDTH, HEIGHT = 640, 480


def varint(data, offset):
    value = 0
    shift = 0
    while data[offset] & 128:
        value |= (data[offset] & 127) << shift
        shift += 7
        offset += 1
    return value | (data[offset] << shift), offset + 1


def length_fields(data):
    offset = 0
    while offset < len(data):
        tag, offset = varint(data, offset)
        assert tag & 7 == 2, tag
        size, offset = varint(data, offset)
        yield tag >> 3, data[offset:offset+size]
        offset += size


def nearest_index(timestamps, target):
    pos = bisect.bisect_left(timestamps, target)
    return min(
        range(max(0, pos - 1), min(len(timestamps), pos + 1)),
        key=lambda index: abs(target - timestamps[index]),
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--fps", type=int, choices=(5, 10), required=True)
    args = parser.parse_args()
    source, output = args.source, args.output
    raw_rgb_path = output / "source.h264"
    output.mkdir(parents=True, exist_ok=True)
    for subdir in ("rgb", "depth"):
        (output / subdir).mkdir(exist_ok=True)
    rgb_times = []
    depth_times = []
    depth_bytes = []
    with source.open("rb") as stream, raw_rgb_path.open("wb") as raw_rgb:
        reader = make_reader(stream)
        for _, channel, message in reader.iter_messages(topics=("/rgb", "/depth")):
            fields = dict(length_fields(message.data))
            if channel.topic == "/rgb":
                assert fields[4] == b"h264"
                rgb_times.append(message.log_time)
                raw_rgb.write(fields[3])
            else:
                assert fields[3] == b"png"
                depth_times.append(message.log_time)
                depth_bytes.append(fields[2])

    base = rgb_times[0]
    interval = 1_000_000_000 // args.fps
    selected = {
        nearest_index(rgb_times, base + index * interval)
        for index in range(1 + (rgb_times[-1] - base) // interval)
    }
    frames = []
    pair_lags_ms = []
    ranges = []
    ffmpeg = subprocess.Popen(
        [
            imageio_ffmpeg.get_ffmpeg_exe(), "-v", "error", "-f", "h264",
            "-i", str(raw_rgb_path), "-vf", "setpts=N", "-fps_mode", "passthrough",
            "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
        ],
        stdout=subprocess.PIPE,
    )
    assert ffmpeg.stdout is not None
    frame_size = WIDTH * HEIGHT * 3
    for index, stamp in enumerate(rgb_times):
        data = ffmpeg.stdout.read(frame_size)
        assert len(data) == frame_size, (index, len(data))
        if index not in selected:
            continue
        depth_index = nearest_index(depth_times, stamp)
        lag_ms = (depth_times[depth_index] - stamp) / 1e6
        if abs(lag_ms) > 20:
            print(f"Skipped frame {index}: RGB/depth lag {lag_ms:.2f} ms")
            continue
        image_path = f"rgb/{index:04}.jpg"
        depth_path = f"depth/{index:04}.png"
        Image.frombytes("RGB", (WIDTH, HEIGHT), data).save(
            output / image_path, quality=96, subsampling=0,
        )
        depth = depth_bytes[depth_index]
        assert depth[:8] == b"\x89PNG\r\n\x1a\n"
        assert depth[24] == 16
        with Image.open(io.BytesIO(depth)) as decoded_depth:
            assert decoded_depth.size == (WIDTH, HEIGHT)
            depth_array = np.asarray(decoded_depth)
            valid = depth_array[depth_array > 0]
            ranges.append((int(valid.min()), int(valid.max())))
        (output / depth_path).write_bytes(depth)
        pair_lags_ms.append(abs(lag_ms))
        frames.append({
            "time": round((stamp - base) / 1e9, 9),
            "image": image_path,
            "depth": depth_path,
        })
    assert not ffmpeg.stdout.read(1)
    assert ffmpeg.wait() == 0

    manifest = {
        "source": "TUM RGB-D SLAM Benchmark, freiburg3_walking_static (Sturm et al., IROS 2012), CC BY 4.0; Voxel51/TUM-RGBD MCAP conversion.",
        "depthUnitsPerMetre": 5000,
        "frames": frames,
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    raw_rgb_path.unlink()
    print(f"{len(rgb_times)} RGB source frames; {len(depth_times)} depth source frames")
    print(f"{len(frames)} pairs; max timestamp skew {max(pair_lags_ms):.3f} ms")
    print(f"Valid raw depth overall range [{min(lo for lo, _ in ranges)}, {max(hi for _, hi in ranges)}]")
    print(f"Selected span {frames[0]['time']:.5f}–{frames[-1]['time']:.5f} seconds")
    for batch, first in enumerate(range(0, len(frames), 45)):
        selections = frames[first:first+45:2]
        sheet = Image.new("RGB", (5*160, ((len(selections)+4)//5)*142), "white")
        draw = ImageDraw.Draw(sheet)
        for position, frame in enumerate(selections):
            x, y = (position % 5)*160, (position // 5)*142
            with Image.open(output / frame["image"]) as photo:
                sheet.paste(photo.resize((160, 120)), (x, y))
            draw.text((x+3, y+122), f"{frame['time']:.3f}s {Path(frame['image']).stem}", fill="black")
        sheet.save(output / f"contact-{batch}.jpg")


if __name__ == "__main__":
    main()

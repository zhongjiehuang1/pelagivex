#!/usr/bin/env python3
"""Reproduce the development TUM 5 Hz torso depth audit."""

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

# RGB-only manual torso clicks; width 240, height 180. Distinct identities
# are defined by black t-shirt and plaid shirt, independent of tracker IDs.
CLICKS = {
    142: ((15, 61), (165, 87)),
    148: ((25, 67), (163, 81)),
    154: ((18, 63), (155, 77)),
    160: ((13, 64), (157, 69)),
    166: ((8, 62), (150, 71)),
    172: ((10, 64), (139, 72)),
    178: ((5, 56), (143, 76)),
    184: ((6, 56), (165, 78)),
    189: ((7, 61), (181, 80)),
    195: ((6, 59), (199, 82)),
    201: ((5, 58), (223, 84)),
    398: ((6, 65), (215, 75)),
    404: ((10, 60), (198, 70)),
    410: ((19, 63), (184, 77)),
    416: ((22, 68), (183, 70)),
    422: ((21, 68), (164, 79)),
    428: ((52, 70), (165, 78)),
    434: ((78, 65), (156, 76)),
    440: ((113, 66), (163, 72)),
    446: ((151, 74), (115, 77)),
    452: ((190, 70), (117, 69)),
    458: ((208, 77), (103, 81)),
    464: ((232, 78), (98, 82)),
    469: ((231, 72), (95, 84)),
}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="Extracted 5 Hz walking_static directory")
    root = parser.parse_args().input
    manifest = json.loads((root / "manifest.json").read_text())
    output = []
    sheet = Image.new("RGB", (960, ((len(CLICKS)+3)//4)*203), "white")
    draw = ImageDraw.Draw(sheet)
    for frame in manifest["frames"]:
        index = int(Path(frame["image"]).stem)
        if index not in CLICKS:
            continue
        points = CLICKS[index]
        depth = np.asarray(Image.open(root / frame["depth"]))
        values = []
        pixels = []
        fractions = []
        iqrs = []
        for x, y in points:
            x, y = round(x*8/3), round(y*8/3)
            patch = depth[y-5:y+6, x-5:x+6]
            valid = patch[patch > 0]
            values.append(round(float(np.median(valid))/5000, 3) if valid.size else None)
            pixels.append([x, y])
            fractions.append(round(float(valid.size / patch.size), 3))
            iqrs.append(round(float(np.percentile(valid, 75) - np.percentile(valid, 25))/5000, 3) if valid.size else None)
        print(index, frame["time"], values, fractions, iqrs)
        position = len(output)
        x_base, y_base = (position % 4)*240, (position // 4)*203
        with Image.open(root / frame["image"]) as photo:
            sheet.paste(photo.resize((240, 180)), (x_base, y_base))
        for (x, y), color in zip(points, ("red", "cyan")):
            draw.ellipse((x_base+x-3, y_base+y-3, x_base+x+3, y_base+y+3), outline=color, width=2)
        draw.text((x_base+2, y_base+182), f'{frame["time"]:.3f}s {values} #{index}', fill="black")
        output.append({
            "time": frame["time"], "image": frame["image"], "depth": frame["depth"],
            "subjects": {
                "black": {"pixel": pixels[0], "depthMetres": values[0], "validFraction": fractions[0], "iqrMetres": iqrs[0]},
                "plaid": {"pixel": pixels[1], "depthMetres": values[1], "validFraction": fractions[1], "iqrMetres": iqrs[1]},
            },
        })
    sheet.save(root / "swap-clicks.jpg")
    (root / "swap-clicks.json").write_text(json.dumps({
        "method": "Manual torso centers selected on source RGB only, sampled 11x11 patch median of positive registered raw sensor depth, 5000 units per metre.",
        "frames": output,
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()

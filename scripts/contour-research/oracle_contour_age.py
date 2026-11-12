"""Diagnostic optimistic test: perfect source masks, current boxes and identities.

Measures the best-case limitations of box-affine contour reuse, not SAM/detector
accuracy. Frame gaps are reported directly; no recording FPS is assumed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import types
import ssl
import urllib.request
import certifi
import cv2
import numpy as np
from PIL import Image


def official_metrics(cache):
    cache.mkdir(parents=True, exist_ok=True)
    base = "https://raw.githubusercontent.com/davisvideochallenge/davis2017-evaluation/4053b4674e78c120417a3052343a513e072350a4/"
    for local, remote in (("metrics.py", "davis2017/metrics.py"), ("LICENSE", "LICENSE")):
        path = cache / local
        if not path.exists():
            with urllib.request.urlopen(base + remote, context=ssl.create_default_context(cafile=certifi.where())) as response:
                path.write_bytes(response.read())
    source = (cache / "metrics.py").read_text()
    digest = hashlib.sha256(source.encode()).hexdigest()
    if digest != "a71bfb6d2da563ebf50251bda9876cf0b4b6193842543b0a3a286190529e26be":
        raise ValueError("DAVIS metric source differs from the pinned revision")
    module = types.ModuleType("davis_official_metrics")
    # The only scikit-image dependency is an integer-radius binary disk. Construct
    # that same Euclidean disk in NumPy; preserve the official J/F code otherwise.
    def disk(radius):
        radius = int(radius)
        y, x = np.ogrid[-radius:radius+1, -radius:radius+1]
        return (x*x+y*y <= radius*radius).astype(np.uint8)
    module.__dict__["_numpy_disk"] = disk
    exec(compile(source.replace("from skimage.morphology import disk", "disk = _numpy_disk"),
                 str(cache / "metrics.py"), "exec"), module.__dict__)
    return module, digest


def bbox(mask):
    y, x = np.nonzero(mask)
    return (int(x.min()), int(y.min()), int(x.max())+1, int(y.max())+1) if len(x) else None


def warp(mask, old, new):
    ox, oy, ex, ey = old
    nx, ny, fx, fy = new
    sx, sy = (ex-ox)/(fx-nx), (ey-oy)/(fy-ny)
    matrix = np.array([[sx, 0, ox-sx*nx+(sx-1)*.5], [0, sy, oy-sy*ny+(sy-1)*.5]], dtype=np.float32)
    return cv2.warpAffine(mask.astype(np.uint8), matrix, (mask.shape[1], mask.shape[0]),
                          flags=cv2.INTER_NEAREST | cv2.WARP_INVERSE_MAP).astype(bool)


def eligible(old, new):
    ow, oh = old[2]-old[0], old[3]-old[1]
    nw, nh = new[2]-new[0], new[3]-new[1]
    intersection = max(0, min(old[2], new[2])-max(old[0], new[0])) * max(0, min(old[3], new[3])-max(old[1], new[1]))
    iou = intersection/(ow*oh+nw*nh-intersection)
    return .7 <= nw/ow <= 1.4 and .7 <= nh/oh <= 1.4 and iou >= .45


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", type=Path, default=Path(".cache/contour-research/davis/DAVIS"))
    parser.add_argument("--output", type=Path, default=Path(".cache/contour-research/oracle-contour-age.json"))
    args = parser.parse_args()
    metrics, digest = official_metrics(Path(".cache/contour-research/davis-evaluation"))
    probe = np.zeros((32, 32), dtype=bool); probe[8:24, 8:24] = True
    assert metrics.db_eval_iou(probe, probe) == metrics.db_eval_boundary(probe, probe) == 1
    assert np.array_equal(warp(probe, bbox(probe), bbox(probe)), probe)
    records, summary = [], []
    for sequence in ("blackswan", "dance-twirl"):
        paths = sorted((args.dataset / "Annotations/480p" / sequence).glob("*.png"))
        masks = [np.asarray(Image.open(path)) for path in paths]
        if not masks:
            raise ValueError(f"No annotations for {sequence}")
        identities = sorted(set(np.unique(np.stack(masks))) - {0, 255})
        for gap in (1, 3, 6, 12):
            rows = []
            for current in range(gap, len(masks)):
                for identity in identities:
                    old = masks[current-gap] == identity; target = masks[current] == identity
                    old_box, new_box = bbox(old), bbox(target)
                    if old_box is None or new_box is None:
                        continue
                    prediction = warp(old, old_box, new_box)
                    row = {"sequence": sequence, "frameGap": gap, "frame": current, "identity": int(identity),
                           "eligibleByProductGeometry": eligible(old_box, new_box),
                           "holdJ": float(metrics.db_eval_iou(target, old)),
                           "holdF": float(metrics.db_eval_boundary(target, old)),
                           "affineJ": float(metrics.db_eval_iou(target, prediction)),
                           "affineF": float(metrics.db_eval_boundary(target, prediction))}
                    rows.append(row)
            admitted = [row for row in rows if row["eligibleByProductGeometry"]]
            entry = {"sequence": sequence, "frameGap": gap, "objectFrames": len(rows),
                     "geometryCoverage": len(admitted)/len(rows)}
            for metric in ("holdJ", "holdF", "affineJ", "affineF"):
                entry[metric] = float(np.mean([row[metric] for row in rows]))
                entry[metric+"EligibleOnly"] = float(np.mean([row[metric] for row in admitted])) if admitted else None
            entry["eligibleAffineFBelow08"] = sum(row["affineF"] < .8 for row in admitted)/len(admitted) if admitted else None
            summary.append(entry); records.extend(rows)
    report = {"scope": "Two-sequence oracle diagnostic, not a DAVIS benchmark or live-model accuracy. Perfect source masks/current boxes/identity are supplied by independent human annotation; even these optimistic inputs cannot correct non-affine shape changes.",
              "fpsAssumption": None, "metricSource": "https://github.com/davisvideochallenge/davis2017-evaluation/blob/4053b4674e78c120417a3052343a513e072350a4/davis2017/metrics.py",
              "metricSHA256": digest, "boundaryTolerance": "Official default 0.008 of image diagonal",
              "metricCompatibility": "NumPy Euclidean disk replaces the scikit-image disk dependency only",
              "summary": summary, "perObjectFrame": records}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2)+"\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

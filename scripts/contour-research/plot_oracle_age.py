"""Render the median boundary-F example at a three-frame gap in each diagnostic video."""
import json
from pathlib import Path
import numpy as np
from PIL import Image
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from oracle_contour_age import bbox, warp

data = json.loads(Path(".cache/contour-research/oracle-contour-age.json").read_text())
root = Path(".cache/contour-research/davis/DAVIS")
figure, axes = plt.subplots(2, 3, figsize=(12, 6.6))
for row, sequence in enumerate(("blackswan", "dance-twirl")):
    records = sorted([r for r in data["perObjectFrame"] if r["sequence"] == sequence and r["frameGap"] == 3],
                     key=lambda r: r["affineF"])
    record = records[len(records)//2]
    index, identity = record["frame"], record["identity"]
    masks = sorted((root / "Annotations/480p" / sequence).glob("*.png"))
    images = sorted((root / "JPEGImages/480p" / sequence).glob("*.jpg"))
    old = np.asarray(Image.open(masks[index-3])) == identity
    current = np.asarray(Image.open(masks[index])) == identity
    propagated = warp(old, bbox(old), bbox(current))
    for column, frame, mask in ((0, index-3, old), (1, index, current), (2, index, current)):
        axes[row, column].imshow(Image.open(images[frame]))
        axes[row, column].contour(mask, levels=[.5], colors=["lime"], linewidths=.8)
    axes[row, 0].set_title(f"{sequence}: source frame {index-3}")
    axes[row, 1].set_title(f"Current frame {index}: human annotation")
    axes[row, 2].contour(propagated, levels=[.5], colors=["magenta"], linewidths=.8)
    axes[row, 2].set_title(f"Box warp: F={record['affineF']:.3f}, J={record['affineJ']:.3f}")
for axis in axes.flat:
    axis.axis("off")
figure.suptitle("Perfect old mask + perfect current box and identity; 3-frame age\n"
                "Green: current annotation. Magenta: propagated contour. Median-F examples.", fontsize=11)
figure.tight_layout()
figure.savefig(".cache/contour-research/oracle-warp-examples.png", dpi=140)

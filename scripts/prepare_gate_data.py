#!/usr/bin/env python3
"""Prepare a one-class YOLO-format research subset of the SAUVC gate dataset.

The upstream train/valid/test split is retained. It does not disclose video or
scene grouping, so near-duplicate leakage and real-world generalisation remain
unverified. Exact image duplicates across splits are excluded.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'data/sauvc/Dataset'
DEST = ROOT / 'data/gate-only'

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--train', type=int, default=1000)
    parser.add_argument('--valid', type=int, default=120)
    parser.add_argument('--test', type=int, default=150)
    args = parser.parse_args()
    rng = random.Random(20261030)
    seen: set[str] = set()
    report = {}
    for split, limit in [('test', args.test), ('valid', args.valid), ('train', args.train)]:
        images = sorted((SOURCE / split / 'images').glob('*.jpg'))
        rng.shuffle(images)
        dst_images = DEST / split / 'images'
        dst_labels = DEST / split / 'labels'
        dst_images.mkdir(parents=True, exist_ok=True)
        dst_labels.mkdir(parents=True, exist_ok=True)
        if any(dst_images.iterdir()) or any(dst_labels.iterdir()):
            raise RuntimeError(f'Refusing to overwrite existing subset: {DEST / split}')
        positives = duplicates = missing = 0
        for img in images:
            label = SOURCE / split / 'labels' / (img.stem + '.txt')
            if not label.exists():
                missing += 1
                continue
            sha = hashlib.sha256(img.read_bytes()).hexdigest()
            if sha in seen:
                duplicates += 1
                continue
            original = [line.strip() for line in label.read_text().splitlines() if line.strip()]
            gate = [line for line in original if line.split()[0] == '0']
            seen.add(sha)
            (dst_images / img.name).symlink_to(img.resolve())
            (dst_labels / label.name).write_text(('\n'.join(gate) + '\n') if gate else '')
            positives += bool(gate)
            if len(list(dst_images.iterdir())) >= limit:
                break
        count = len(list(dst_images.iterdir()))
        report[split] = {'images': count, 'images_with_gate': positives,
                         'exact_duplicates_skipped': duplicates, 'missing_labels': missing}
    (DEST / 'data.yaml').write_text("names: ['Gate']\nnc: 1\n")
    (DEST / 'manifest.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))

if __name__ == '__main__':
    main()

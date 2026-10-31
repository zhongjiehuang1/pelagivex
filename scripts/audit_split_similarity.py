#!/usr/bin/env python3
"""Count visually near-duplicate frames across a prepared data split.

Difference hashes are only a heuristic. A clean result does not prove scenes or
video sequences are independent.
"""
import json
from pathlib import Path
from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'data/gate-only'

def difference_hash(path):
    with Image.open(path) as image:
        pixels = list(ImageOps.grayscale(image).resize((9, 8)).getdata())
    bits = 0
    for y in range(8):
        for x in range(8):
            bits = (bits << 1) | (pixels[y*9+x] > pixels[y*9+x+1])
    return bits

hashes = {split: [(p.name, difference_hash(p)) for p in sorted((BASE/split/'images').glob('*.jpg'))]
          for split in ('train', 'valid', 'test')}
result = {}
for name in ('valid', 'test'):
    matches = []
    for filename, value in hashes[name]:
        distance, train_filename = min(((value ^ h).bit_count(), f) for f, h in hashes['train'])
        if distance <= 3:
            matches.append({'file': filename, 'nearest_training_file': train_filename, 'distance': distance})
    result[name] = {'images': len(hashes[name]), 'within_3_bits_of_train': len(matches), 'matches': matches}
out = ROOT / 'runs' / 'split-similarity.json'
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({name: {k: v for k, v in entry.items() if k != 'matches'}
                  for name, entry in result.items()}, indent=2))

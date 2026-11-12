#!/usr/bin/env python3
"""Convert the prepared single-class YOLO subset to RF-DETR's COCO layout."""
import json
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'data/gate-only'
DEST = ROOT / 'data/gate-coco'

for split in ('train', 'valid', 'test'):
    dest = DEST / split
    dest.mkdir(parents=True, exist_ok=True)
    image_items, annotation_items = [], []
    for image_id, path in enumerate(sorted((SOURCE / split / 'images').glob('*.jpg')), 1):
        with Image.open(path) as image:
            width, height = image.size
        link = dest / path.name
        if link.is_symlink():
            if link.resolve() != path.resolve():
                raise RuntimeError(f'Unexpected existing symlink: {link}')
        elif link.exists():
            raise RuntimeError(f'Refusing to replace existing file: {link}')
        else:
            link.symlink_to(path.resolve())
        image_items.append({'id': image_id, 'file_name': path.name,
                            'width': width, 'height': height})
        label_path = SOURCE / split / 'labels' / (path.stem + '.txt')
        for line in label_path.read_text().splitlines():
            parts = line.split()
            if len(parts) != 5 or parts[0] != '0':
                raise ValueError(f'Invalid Gate label in {label_path}: {line}')
            cx, cy, bw, bh = map(float, parts[1:])
            x1 = max(0.0, (cx - bw/2)*width)
            y1 = max(0.0, (cy - bh/2)*height)
            x2 = min(float(width), (cx + bw/2)*width)
            y2 = min(float(height), (cy + bh/2)*height)
            if x2 <= x1 or y2 <= y1:
                raise ValueError(f'Degenerate box in {label_path}: {line}')
            annotation_items.append({'id': len(annotation_items)+1, 'image_id': image_id,
                 'category_id': 0, 'bbox': [x1, y1, x2-x1, y2-y1],
                 'area': (x2-x1)*(y2-y1), 'iscrowd': 0})
    document = {'images': image_items, 'annotations': annotation_items,
                'categories': [{'id': 0, 'name': 'Gate', 'supercategory': 'structure'}],
                'info': {'description': 'SAUVC Gate research subset'}, 'licenses': []}
    (dest / '_annotations.coco.json').write_text(json.dumps(document))
    print(split, len(image_items), 'images', len(annotation_items), 'gate boxes')

#!/usr/bin/env python3
"""Prepare previously unused source test images for one final evaluation.

This does not create an independent-scene split; upstream recording provenance
is not available. Exact duplicates of train/valid/exploratory-test are removed.
"""
import hashlib
import json
from pathlib import Path
from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[1]
src = ROOT/'data/sauvc/Dataset/test'
subset = ROOT/'data/gate-only'
dest = ROOT/'data/gate-coco/finaltest'
dest.mkdir(parents=True, exist_ok=True)
if any(dest.iterdir()):
    raise RuntimeError('Final holdout already exists; refusing to regenerate it')

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def dhash(path):
    with Image.open(path) as im:
        px = list(ImageOps.grayscale(im).resize((9,8)).getdata())
    return sum((px[y*9+x] > px[y*9+x+1]) << (63-(y*8+x))
               for y in range(8) for x in range(8))

used = {sha(p) for split in ('train','valid','test') for p in (subset/split/'images').glob('*.jpg')}
train_hashes = [dhash(p) for p in (subset/'train/images').glob('*.jpg')]
exploratory = {p.name for p in (subset/'test/images').glob('*.jpg')}
images, annotations, near = [], [], []
for path in sorted((src/'images').glob('*.jpg')):
    if path.name in exploratory or sha(path) in used:
        continue
    label = src/'labels'/(path.stem+'.txt')
    if not label.exists():
        continue
    with Image.open(path) as im:
        width,height = im.size
    image_id = len(images)+1
    (dest/path.name).symlink_to(path.resolve())
    images.append({'id':image_id,'file_name':path.name,'width':width,'height':height})
    used.add(sha(path))
    d = dhash(path)
    if min((d ^ x).bit_count() for x in train_hashes) <= 3:
        near.append(path.name)
    for line in label.read_text().splitlines():
        parts = line.split()
        if len(parts) != 5 or parts[0] != '0':
            continue
        cx,cy,bw,bh = map(float,parts[1:])
        x1,y1 = max(0.,(cx-bw/2)*width),max(0.,(cy-bh/2)*height)
        x2,y2 = min(float(width),(cx+bw/2)*width),min(float(height),(cy+bh/2)*height)
        if x2<=x1 or y2<=y1: raise ValueError(f'Degenerate box: {path}')
        annotations.append({'id':len(annotations)+1,'image_id':image_id,'category_id':0,
                            'bbox':[x1,y1,x2-x1,y2-y1],'area':(x2-x1)*(y2-y1),'iscrowd':0})
document = {'images':images,'annotations':annotations,
            'categories':[{'id':0,'name':'Gate','supercategory':'structure'}]}
(dest/'_annotations.coco.json').write_text(json.dumps(document))
report={'images':len(images),'gate_boxes':len(annotations),'near_train_dhash_le3':len(near),
        'near_train_files':near,'limitation':'Upstream video/scene grouping unknown'}
(ROOT/'runs/finalholdout-similarity.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k != 'near_train_files'},indent=2))

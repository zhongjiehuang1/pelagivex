#!/usr/bin/env python3
"""Freeze the checkpoint based only on validation AP@[0.50:0.95]."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
records = []
for run in ('gate-valid', 'gate-3epoch'):
    path = ROOT/'runs'/run/'log.txt'
    for line in path.read_text().splitlines():
        record = json.loads(line)
        records.append({'run':run, 'epoch':record['epoch']+1,
                        'validation_ap_50_95':record['test_coco_eval_bbox'][0],
                        'validation_ap_50':record['test_coco_eval_bbox'][1]})
best = max(records,key=lambda r:r['validation_ap_50_95'])
checkpoint = ROOT/'runs'/best['run']/'checkpoint_best_total.pth'
if not checkpoint.is_file():
    raise RuntimeError(f'Missing best checkpoint: {checkpoint}')
result={'selection':'highest RF-DETR COCO AP@[0.50:0.95] on validation only',
        'validation_epochs':records, 'selected':best,
        'checkpoint':str(checkpoint.relative_to(ROOT)),
        'checkpoint_sha256':hashlib.sha256(checkpoint.read_bytes()).hexdigest()}
out=ROOT/'runs/selected-model.json'
out.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))

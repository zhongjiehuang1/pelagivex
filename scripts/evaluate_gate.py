#!/usr/bin/env python3
"""Measure honest thresholded one-class detection on held-out data.

Confidence is chosen on validation data only. All test figures are then fixed.
The source split may contain same-video or scene leakage; an additional dHash
screened sensitivity subset is reported without claiming scene independence.
"""
from __future__ import annotations
import argparse
import json
import time
from pathlib import Path
import numpy as np
from PIL import Image
from rfdetr import RFDETRNano

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'data/gate-coco'
SCORES = [0.05, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7]

def load_examples(split):
    raw = json.loads((DATA/split/'_annotations.coco.json').read_text())
    by_id = {x['id']: {'name': x['file_name'], 'truth': []} for x in raw['images']}
    for a in raw['annotations']:
        x, y, w, h = a['bbox']
        by_id[a['image_id']]['truth'].append([x, y, x+w, y+h])
    return list(by_id.values())

def overlap(a, b):
    w = max(0., min(a[2], b[2])-max(a[0], b[0]))
    h = max(0., min(a[3], b[3])-max(a[1], b[1]))
    intersection = w*h
    area_a = max(0., a[2]-a[0])*max(0., a[3]-a[1])
    area_b = max(0., b[2]-b[0])*max(0., b[3]-b[1])
    union = area_a+area_b-intersection
    return intersection/union if union else 0.

def metrics(items, threshold):
    tp = fp = fn = 0
    for item in items:
        remaining = set(range(len(item['truth'])))
        for det in [d for d in item['detections'] if d['score'] >= threshold][:25]:
            best = max(remaining, key=lambda i: overlap(det['box'], item['truth'][i]), default=None)
            if best is not None and overlap(det['box'], item['truth'][best]) >= .5:
                tp += 1
                remaining.remove(best)
            else:
                fp += 1
        fn += len(remaining)
    precision = tp/(tp+fp) if tp+fp else 0.
    recall = tp/(tp+fn) if tp+fn else 0.
    return {'images': len(items), 'tp':tp, 'fp':fp, 'fn':fn,
            'precision':precision, 'recall':recall,
            'f1':2*precision*recall/(precision+recall) if precision+recall else 0.}

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--checkpoint', required=True)
    p.add_argument('--device', default='mps')
    p.add_argument('--output', default='runs/gate-evaluation.json')
    p.add_argument('--test-split', choices=['test', 'finaltest'], default='test')
    args = p.parse_args()
    model = RFDETRNano(pretrain_weights=str(ROOT/args.checkpoint), device=args.device, num_classes=1)
    predictions = {}
    timings = []
    validation = None
    selected = None
    for split in ('valid',args.test_split):
        if split != 'valid':
            validation = {str(t): metrics(predictions['valid'], t) for t in SCORES}
            selected = max(SCORES, key=lambda t: (validation[str(t)]['f1'], t))
            freeze = {'checkpoint':args.checkpoint, 'threshold':selected,
                      'selection':'maximum validation F1, ties favor higher threshold',
                      'validation':validation}
            freeze_file = ROOT/'runs/frozen-validation-threshold.json'
            freeze_file.parent.mkdir(parents=True, exist_ok=True)
            freeze_file.write_text(json.dumps(freeze, indent=2)+'\n')
            print('Frozen validation threshold:', selected, flush=True)
        examples = load_examples(split)
        for index, item in enumerate(examples):
            start = time.perf_counter()
            # Predict on actual image pixels. Boxes and scores are retained, never prefilled.
            det = model.predict(str(DATA/split/item['name']), threshold=0.01)
            timings.append(time.perf_counter()-start)
            pairs = sorted(zip(det.confidence.tolist(), det.class_id.tolist(), det.xyxy.tolist()),
                           reverse=True)
            item['detections'] = [{'score':float(score),'box':[float(x) for x in box]}
                                  for score, class_id, box in pairs if class_id == 0][:25]
            if (index+1) % 20 == 0:
                print(split, index+1, '/', len(examples), flush=True)
        predictions[split] = examples
    if args.test_split == 'finaltest':
        sim = json.loads((ROOT/'runs/finalholdout-similarity.json').read_text())
        excluded = set(sim['near_train_files'])
    else:
        sim = json.loads((ROOT/'runs/split-similarity.json').read_text())
        excluded = {item['file'] for item in sim['test']['matches']}
    test_items = predictions[args.test_split]
    screened = [x for x in test_items if x['name'] not in excluded]
    report = {'checkpoint':args.checkpoint, 'device':args.device,
              'threshold_selected_on_validation':selected,
              'validation_threshold_sweep':validation,
              'test_split':args.test_split,
              'test_full':metrics(test_items,selected),
              'test_dhash_screened_sensitivity':metrics(screened,selected),
              'near_duplicate_screen':'64-bit dHash distance <=3 from a training frame; heuristic only',
              'data_limitation':'Original train/validation/test video or scene grouping unknown; not an independent-scene assessment.',
              'median_inference_seconds':float(np.median(timings)),
              'test_image_predictions':test_items}
    output = ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k != 'test_image_predictions'},indent=2))

if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Evaluate predefined cross-source simulated gate scenes at a frozen threshold."""
import argparse
import json
from pathlib import Path
from rfdetr import RFDETRNano
from evaluate_gate import metrics

ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'data/external-demo'
p=argparse.ArgumentParser()
p.add_argument('--checkpoint',required=True)
p.add_argument('--device',default='mps')
p.add_argument('--threshold',type=float,required=True)
p.add_argument('--output',default='runs/synthetic-challenge.json')
args=p.parse_args()
raw=json.loads((BASE/'annotations-v2.json').read_text())
ids={image['id']:image for image in raw['images']}
by_name={image['file_name'].rsplit('/',1)[-1]:image for image in raw['images']}
gates={}
for annotation in raw['annotations']:
    if annotation['category_id']==1:
        x,y,w,h=annotation['bbox']
        gates.setdefault(annotation['image_id'],[]).append([x,y,x+w,y+h])
model=RFDETRNano(pretrain_weights=str(ROOT/args.checkpoint),device=args.device,num_classes=1)
items=[]
for path in sorted((BASE/'challenge').glob('*.png')):
    image=by_name[path.name]
    detection=model.predict(str(path),threshold=.01)
    pairs=sorted(zip(detection.confidence.tolist(),detection.class_id.tolist(),detection.xyxy.tolist()),reverse=True)
    items.append({'name':path.name,'truth':gates.get(image['id'],[]),
                  'detections':[{'score':float(score),'box':[float(x) for x in box]}
                                for score,cls,box in pairs if cls==0][:25]})
result={'dataset':'jack-www/sauvc-v1 v2 COCO, 10 preselected held-out synthetic layouts',
        'license':'MIT as dataset publisher declares', 'checkpoint':args.checkpoint,
        'threshold_frozen_from_real_validation':args.threshold,
        'metrics_iou_0_5':metrics(items,args.threshold),'predictions':items,
        'limitation':'Only 10 synthetic images; this is not evidence of real-world generalization.'}
output=ROOT/args.output
output.parent.mkdir(parents=True,exist_ok=True)
output.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k!='predictions'},indent=2))

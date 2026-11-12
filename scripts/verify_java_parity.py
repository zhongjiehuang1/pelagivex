#!/usr/bin/env python3
"""Compare local Java/ONNX detections against recorded RF-DETR Python predictions.

This validates the inference adapter; it is not an assessment of generalization.
Requires the locally built Maven classes and project-local Maven cache.
"""
from __future__ import annotations
import argparse
import glob
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', type=Path, default=ROOT / 'model/gate.onnx')
    parser.add_argument('--evaluation', type=Path, default=ROOT / 'runs/gate-evaluation.json')
    parser.add_argument('--images', type=Path, default=ROOT / 'data/gate-coco/test')
    parser.add_argument('--output', type=Path, default=ROOT / 'runs/java-parity.json')
    args = parser.parse_args()
    document = json.loads(args.evaluation.read_text())
    threshold = float(document['threshold_selected_on_validation'])
    rows = document['test_image_predictions']
    has_pred = lambda row: any(d['score'] > threshold for d in row['detections'])
    selected = [r for r in rows if has_pred(r)][:3]
    selected += [r for r in rows if r['truth'] and not has_pred(r)][:1]
    selected += [r for r in rows if not r['truth'] and not has_pred(r)][:1]
    if len(selected) < 3:
        raise SystemExit('Not enough distinct cases to run meaningful parity checks.')
    patterns = [
        'com/microsoft/onnxruntime/onnxruntime/*/*.jar',
        'com/fasterxml/jackson/core/*/*/*.jar',
        'com/drewnoakes/metadata-extractor/*/*.jar',
        'com/adobe/xmp/xmpcore/*/*.jar',
    ]
    jars = [name for pattern in patterns for name in glob.glob(str(ROOT / '.cache/maven' / pattern))]
    classpath = os.pathsep.join([str(ROOT/'target/test-classes'), str(ROOT/'target/classes'), *jars])
    java = str(Path(os.environ['JAVA_HOME']) / 'bin/java') if os.environ.get('JAVA_HOME') else shutil.which('java')
    if not java:
        raise SystemExit('A Java runtime is required; set JAVA_HOME.')
    environment = dict(os.environ, TMPDIR=str(ROOT/'.tmp'))
    report = []
    passed = True
    for row in selected:
        image = (args.images / row['name']).resolve()
        if not image.is_relative_to(ROOT):
            raise SystemExit('Invalid image path in evaluation file.')
        process = subprocess.run([java, '-Djava.io.tmpdir='+str(ROOT/'.tmp'), '-cp', classpath,
                                  'com.pelagivex.ModelCheck', str(args.model.resolve()), str(image),
                                  '0', str(threshold), '1'], capture_output=True, text=True,
                                 env=environment, timeout=180, check=True)
        actual = json.loads(process.stdout)
        expected = [d for d in row['detections'] if d['score'] > threshold][:25]
        actual_detections = actual['detections']
        equal_count = len(expected) == len(actual_detections)
        max_score_delta = 0.0
        max_box_delta = 0.0
        for a, b in zip(expected, actual_detections):
            max_score_delta = max(max_score_delta, abs(a['score'] - b['confidence']))
            clamped = [max(0, min(a['box'][i], actual['width'] if i % 2 == 0 else actual['height'])) for i in range(4)]
            max_box_delta = max(max_box_delta, *(abs(clamped[i] - b['box'][i]) for i in range(4)))
        case_ok = equal_count and max_score_delta <= 0.005 and max_box_delta <= 2.0
        passed = passed and case_ok
        report.append({'image':row['name'], 'expected_count':len(expected), 'actual_count':len(actual_detections),
                       'max_score_delta':max_score_delta, 'max_box_delta_px':max_box_delta,
                       'inference_ms':actual['run_ms'][0], 'passed':case_ok})
    digest = hashlib.sha256()
    with args.model.open('rb') as src:
        for block in iter(lambda: src.read(1024*1024), b''): digest.update(block)
    result = {'model':str(args.model.relative_to(ROOT) if args.model.is_relative_to(ROOT) else args.model),
              'model_sha256':digest.hexdigest(), 'threshold':threshold, 'cases':report, 'passed':passed}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result, indent=2))
    if not passed: raise SystemExit(1)

if __name__ == '__main__':
    main()

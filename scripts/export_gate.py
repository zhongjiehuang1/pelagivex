#!/usr/bin/env python3
"""Export our one-class checkpoint to ONNX and report the runtime contract."""
import argparse
import hashlib
import json
from pathlib import Path
import onnx
import onnxruntime as ort
from rfdetr import RFDETRNano

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--checkpoint', required=True)
p.add_argument('--output', default='model/gate.onnx')
args = p.parse_args()
checkpoint = (ROOT / args.checkpoint).resolve()
output = (ROOT / args.output).resolve()
export_dir = ROOT / 'work/model/export'
export_dir.mkdir(parents=True, exist_ok=True)
model = RFDETRNano(pretrain_weights=str(checkpoint), device='cpu', num_classes=1)
model.export(output_dir=str(export_dir), verbose=False)
generated = export_dir / 'inference_model.onnx'
onnx.checker.check_model(str(generated))
session = ort.InferenceSession(str(generated), providers=['CPUExecutionProvider'])
contract = {'input': [{'name': i.name, 'shape': i.shape, 'type': i.type} for i in session.get_inputs()],
            'output': [{'name': i.name, 'shape': i.shape, 'type': i.type} for i in session.get_outputs()],
            'source_checkpoint': args.checkpoint,
            'checkpoint_sha256': hashlib.sha256(checkpoint.read_bytes()).hexdigest(),
            'onnx_sha256': hashlib.sha256(generated.read_bytes()).hexdigest(),
            'class_id': 0, 'class_name': 'Gate',
            'preprocessing': 'RGB tensor, values 0-1, ImageNet normalization, bilinear 384x384 with antialias',
            'postprocessing': 'sigmoid on class 0; boxes cxcywh normalized to image dimensions; top 25'}
output.parent.mkdir(parents=True, exist_ok=True)
generated.replace(output)
(output.parent/(output.stem+'-contract.json')).write_text(json.dumps(contract, indent=2)+'\n')
print(json.dumps(contract, indent=2))

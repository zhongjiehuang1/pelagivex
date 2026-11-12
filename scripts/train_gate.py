#!/usr/bin/env python3
"""Fine-tune RF-DETR Nano on the prepared Gate-only research subset."""
from __future__ import annotations

import argparse
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--epochs', type=int, default=8)
    parser.add_argument('--output', default='runs/gate')
    parser.add_argument('--resume')
    args = parser.parse_args()
    os.chdir(ROOT / 'model')
    from rfdetr import RFDETRNano
    model = RFDETRNano(device='mps')
    options = dict(dataset_dir=str(ROOT / 'data/gate-coco'),
                   output_dir=str(ROOT / args.output), epochs=args.epochs,
                   batch_size=2, grad_accum_steps=2, num_workers=0,
                   tensorboard=False, wandb=False, multi_scale=False,
                   use_ema=False, run_test=False, checkpoint_interval=1)
    if args.resume:
        options['resume'] = str(ROOT / args.resume)
    model.train(**options)

if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Fetch ten predefined held-out-layout simulated frames from SAUVC MIT data.

The layout list is fixed before inspecting model predictions. Images are kept
under ignored data/ and are not mixed with training or threshold selection.
"""
import concurrent.futures
import urllib.request
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'data/external-demo/challenge'
OUT.mkdir(parents=True,exist_ok=True)
BASE='https://huggingface.co/datasets/jack-www/sauvc-v1/resolve/main/images/'
LAYOUTS=(4,9,14,19,24,29,34,39,44,49)

def fetch(layout):
    name=f'layout_{layout:03d}__layout_{layout:03d}_view_00__light_0_haze_0.png'
    path=OUT/name
    if path.exists():
        return name
    with urllib.request.urlopen(BASE+name,timeout=90) as response:
        path.write_bytes(response.read())
    return name

with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
    for name in executor.map(fetch,LAYOUTS): print(name,flush=True)

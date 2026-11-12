"""Compare local Base and Large metric-depth candidates on one RGB image.

Output contains model estimates and timings only; it does not establish
accuracy without independently measured ground truth.
"""
import argparse
import gc
import json
import statistics
import time

import numpy as np
import torch
from PIL import Image

from depth import DepthEstimator
from depth_large import LargeDepthEstimator


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('image')
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--x', type=float, default=.5, help='sample x as fraction of image width')
    parser.add_argument('--y', type=float, default=.5, help='sample y as fraction of image height')
    args = parser.parse_args()
    if not 1 <= args.runs <= 20 or not 0 <= args.x < 1 or not 0 <= args.y < 1:
        parser.error('invalid runs or sample coordinates')
    image = Image.open(args.image).convert('RGB')
    image.thumbnail((1280, 720), Image.Resampling.LANCZOS)
    pixels = np.asarray(image)
    output = {'width': image.width, 'height': image.height, 'sample': [args.x, args.y], 'models': {}}
    for name, cls in [('base', DepthEstimator), ('large', LargeDepthEstimator)]:
        start = time.perf_counter()
        model = cls()
        load_ms = (time.perf_counter() - start) * 1000
        model.estimate(pixels)
        times = []
        samples = []
        for _ in range(args.runs):
            start = time.perf_counter()
            depth = model.estimate(pixels)
            if model.device.type == 'mps':
                torch.mps.synchronize()
            times.append((time.perf_counter() - start) * 1000)
            h, w = depth.shape
            x, y = int(args.x * w), int(args.y * h)
            area = depth[max(0,y-4):min(h,y+5),max(0,x-4):min(w,x+5)]
            finite = area[np.isfinite(area) & (area > 0)]
            samples.append(float(np.median(finite)) if finite.size else None)
        output['models'][name] = {'info': model.info, 'load_ms': round(load_ms, 1),
                                  'median_ms': round(statistics.median(times), 1),
                                  'sample_m': samples}
        del depth, model
        gc.collect()
        if torch.backends.mps.is_available():
            torch.mps.empty_cache()
    print(json.dumps(output, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()

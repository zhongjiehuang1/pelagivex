"""Local, uncalibrated indoor monocular distance estimates for the native app."""
import base64
import io
import json
import math
import os
import sys
import time
from contextlib import redirect_stdout
from pathlib import Path

sys.dont_write_bytecode = True
root = Path(sys.argv[1])
sys.path.insert(0, str(root / 'local_vision'))
os.environ.setdefault('TOKENIZERS_PARALLELISM', 'false')
os.environ['OPENBLAS_NUM_THREADS'] = '1'
os.environ['OMP_NUM_THREADS'] = '2'
os.environ['VECLIB_MAXIMUM_THREADS'] = '1'
try:
    with redirect_stdout(sys.stderr):
        import numpy as np
        import torch
        torch.set_num_threads(2)
        from PIL import Image
        from depth import DepthEstimator
        from mask_depth import instance_depth
        estimator = DepthEstimator()
    print(json.dumps({'ready': True}), flush=True)
except Exception as error:
    print(json.dumps({'error': str(error)}), flush=True)
    sys.exit(1)

for line in sys.stdin:
    try:
        started = time.perf_counter()
        request = json.loads(line)
        image = np.asarray(Image.open(io.BytesIO(base64.b64decode(request['image']))).convert('RGB'))
        with redirect_stdout(sys.stderr):
            depth = estimator.estimate(image)
        h, w = depth.shape
        shape = request['prototypeShape']
        if len(shape) != 3 or not (1 <= shape[0] <= 128 and 1 <= shape[1] <= 256 and 1 <= shape[2] <= 256):
            raise ValueError('Invalid prototype shape')
        prototypes = np.frombuffer(base64.b64decode(request['prototypes'], validate=True), dtype='<f2').reshape(shape).astype(np.float32)
        results = {}
        for target in request['targets']:
            z = instance_depth(depth, prototypes, target['coefficients'], target['box'], request['inputSize'])
            if z is None:
                continue
            distance = z
            if math.isfinite(distance) and distance > 0:
                results[str(target['id'])] = round(distance, 2)
        response = {'distances': results, 'workerSeconds': time.perf_counter() - started}
        if 'referenceDepth' in request:
            raw_depth = np.asarray(Image.open(request['referenceDepth']))
            scale = float(request['referenceUnitsPerMetre'])
            if raw_depth.ndim != 2 or not math.isfinite(scale) or scale <= 0:
                raise ValueError('Invalid recorded sensor depth')
            if raw_depth.shape[0] * image.shape[1] != raw_depth.shape[1] * image.shape[0]:
                raise ValueError('Recorded sensor depth must be aligned to the RGB image')
            reference = raw_depth.astype(np.float32) / scale
            reference[raw_depth == 0] = np.nan
            reference_results = {}
            for target in request['targets']:
                z = instance_depth(reference, prototypes, target['coefficients'], target['box'], request['inputSize'])
                if z is not None and math.isfinite(z):
                    reference_results[str(target['id'])] = z
            response['referenceDistances'] = reference_results
        print(json.dumps(response), flush=True)
    except Exception as error:
        print(json.dumps({'error': str(error)}), flush=True)

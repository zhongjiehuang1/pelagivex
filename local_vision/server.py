#!/usr/bin/env python3
"""Loopback-only camera inference service for Pelagivex."""
import argparse
import json
import math
import os
import threading
import time
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parent
MAX_BODY = 8 * 1024 * 1024
MAX_PIXELS = 4_000_000
MIME = {'/': ('index.html', 'text/html; charset=utf-8'),
        '/app.js': ('app.js', 'text/javascript; charset=utf-8'),
        '/style.css': ('style.css', 'text/css; charset=utf-8')}


def target_depth(depth, box):
    """Robust central box estimate; cannot guarantee foreground separation."""
    h, w = depth.shape
    x1, y1, x2, y2 = map(float, box)
    if not all(map(math.isfinite, (x1, y1, x2, y2))) or x2 <= x1 or y2 <= y1:
        return None
    # Crop the outer quarter to reduce contamination from the box background.
    xa, xb = sorted((max(0, min(w, int(x1 + .25 * (x2 - x1)))),
                     max(0, min(w, int(math.ceil(x2 - .25 * (x2 - x1)))))))
    ya, yb = sorted((max(0, min(h, int(y1 + .25 * (y2 - y1)))),
                     max(0, min(h, int(math.ceil(y2 - .25 * (y2 - y1)))))))
    values = depth[ya:yb, xa:xb]
    values = values[np.isfinite(values) & (values > 0)]
    return float(np.median(values)) if values.size else None


class Service(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, detector, depth):
        super().__init__(address, Handler)
        self.detector, self.depth = detector, depth
        self.owl = None
        self.owl_large = None
        self.large_depth = None
        self.pro_depth = None
        self.mixed_depth = None
        self.busy = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    server_version = 'PelagivexLocal/1.0'

    def allowed_host(self):
        return self.headers.get('Host', '').lower() in {
            f'127.0.0.1:{self.server.server_port}', f'localhost:{self.server.server_port}'}

    def send_data(self, status, body, content_type):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.end_headers()
        self.wfile.write(body)

    def json(self, status, obj):
        self.send_data(status, json.dumps(obj, ensure_ascii=False, allow_nan=False).encode(), 'application/json; charset=utf-8')

    def do_GET(self):
        if not self.allowed_host():
            return self.json(403, {'error': 'Invalid host'})
        path = urlsplit(self.path).path
        if path == '/api/health':
            return self.json(200, {'status': 'ok', 'detector': self.server.detector.info,
                                   'depth': self.server.depth.info})
        if path not in MIME:
            return self.json(404, {'error': 'Not found'})
        filename, mime = MIME[path]
        try:
            data = (ROOT / 'web' / filename).read_bytes()
        except OSError:
            return self.json(404, {'error': 'Not found'})
        self.send_data(200, data, mime)

    def do_POST(self):
        if not self.allowed_host() or urlsplit(self.path).path != '/api/analyze':
            return self.json(403, {'error': 'Invalid host or path'})
        origin = self.headers.get('Origin')
        expected = f'http://{self.headers.get("Host", "")}'
        if origin and origin.lower() != expected.lower():
            return self.json(403, {'error': 'Cross-origin request rejected'})
        if self.headers.get('Sec-Fetch-Site', 'same-origin') not in ('same-origin', 'none'):
            return self.json(403, {'error': 'Cross-site request rejected'})
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if size <= 0 or size > MAX_BODY:
                return self.json(413, {'error': 'Image request is too large'})
            content_type = self.headers.get('Content-Type', '')
            if not content_type.lower().startswith('multipart/form-data;'):
                return self.json(400, {'error': 'Expected multipart image'})
            body = self.rfile.read(size)
            msg = BytesParser(policy=policy.default).parsebytes(
                b'Content-Type: ' + content_type.encode('ascii') + b'\r\nMIME-Version: 1.0\r\n\r\n' + body)
            parts = {part.get_param('name', header='content-disposition'): part for part in msg.iter_parts()}
            data = parts['image'].get_payload(decode=True)
            scale = float(parts['scale'].get_content().strip()) if 'scale' in parts else 1.0
            offset = float(parts['offset'].get_content().strip()) if 'offset' in parts else 0.0
            compare_depth = parts['compare_depth'].get_content().strip() if 'compare_depth' in parts else '0'
            compare_model = parts['compare_model'].get_content().strip() if 'compare_model' in parts else 'large'
            if compare_depth not in ('0', '1') or compare_model not in ('large', 'pro', 'mixed'):
                raise ValueError('Invalid comparison selection')
            depth_mode = parts['depth_mode'].get_content().strip() if 'depth_mode' in parts else 'standard'
            if depth_mode not in ('standard', 'mixed', 'large'):
                raise ValueError('Invalid depth mode')
            mode = parts['detector'].get_content().strip() if 'detector' in parts else 'coco'
            prompt_text = parts['prompts'].get_content().strip() if 'prompts' in parts else ''
            prompts = [p.strip() for p in prompt_text.split(',') if p.strip()]
            if mode not in ('coco', 'owl', 'owl_large') or len(prompt_text) > 300 or (mode in ('owl', 'owl_large') and (not 1 <= len(prompts) <= 8 or any(len(p) > 128 for p in prompts))):
                raise ValueError('Invalid detector or prompts')
            if not math.isfinite(scale) or not .01 <= scale <= 100 or not math.isfinite(offset) or not -100 <= offset <= 100:
                raise ValueError('Invalid calibration scale')
            if not data:
                raise ValueError('Missing image')
        except (ValueError, KeyError, TypeError, UnicodeError):
            return self.json(400, {'error': 'Invalid image request or calibration'})
        if not self.server.busy.acquire(blocking=False):
            return self.json(429, {'error': 'Inference busy'})
        try:
            start = time.perf_counter()
            image = cv2.imdecode(np.frombuffer(data, dtype=np.uint8), cv2.IMREAD_COLOR)
            if image is None or image.shape[0] * image.shape[1] > MAX_PIXELS:
                return self.json(400, {'error': 'Invalid or oversized image'})
            image = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
            h, w = image.shape[:2]
            decoded = time.perf_counter()
            if mode == 'owl_large':
                if self.server.owl_large is None:
                    from owl_large import OwlLargeDetector
                    print('Loading optional OWLv2 Large detector...', flush=True)
                    self.server.owl_large = OwlLargeDetector()
                detections = self.server.owl_large.detect(image, prompts)
            elif mode == 'owl':
                if self.server.owl is None:
                    from owl_detector import OwlDetector
                    print('Loading optional OWLv2 text detector...', flush=True)
                    self.server.owl = OwlDetector()
                detections = self.server.owl.detect(image, prompts)
            else:
                detections = self.server.detector.detect(image)
            detected = time.perf_counter()
            if depth_mode == 'large' and compare_depth != '1':
                if self.server.large_depth is None:
                    from depth_large import LargeDepthEstimator
                    print('Loading optional Large depth model...', flush=True)
                    self.server.large_depth = LargeDepthEstimator()
                current_depth = self.server.large_depth
            elif depth_mode == 'mixed' and compare_depth != '1':
                if self.server.mixed_depth is None:
                    from depth_mixed import DepthMixedEstimator
                    self.server.mixed_depth = DepthMixedEstimator(self.server.depth)
                current_depth = self.server.mixed_depth
            else:
                current_depth = self.server.depth
            depth = np.asarray(current_depth.estimate(image))
            estimated = time.perf_counter()
            if depth.ndim != 2:
                raise ValueError('Invalid depth output')
            if depth.shape != (h, w):
                depth = cv2.resize(depth.astype(np.float32), (w, h), interpolation=cv2.INTER_LINEAR)
            out = []
            for d in detections:
                box = [float(v) for v in d['box']]
                confidence = float(d['confidence'])
                if len(box) != 4 or not all(map(math.isfinite, box)) or not math.isfinite(confidence):
                    continue
                z = target_depth(depth, box)
                calibrated_z = z * scale + offset if z is not None else None
                out.append({'label': str(d['label']), 'confidence': confidence,
                            'box': box, 'distance_m': round(calibrated_z, 3) if calibrated_z is not None and math.isfinite(calibrated_z) and calibrated_z > 0 else None})
            large_depth = None
            large_started = time.perf_counter()
            if compare_depth == '1':
                if compare_model == 'mixed':
                    from depth_mixed import DepthMixedEstimator
                    if self.server.mixed_depth is None:
                        self.server.mixed_depth = DepthMixedEstimator(self.server.depth)
                    candidate = self.server.mixed_depth
                elif compare_model == 'pro':
                    if self.server.pro_depth is None:
                        from depth_pro import DepthProEstimator
                        print('Loading optional Depth Pro model...', flush=True)
                        self.server.pro_depth = DepthProEstimator()
                    candidate = self.server.pro_depth
                else:
                    if self.server.large_depth is None:
                        from depth_large import LargeDepthEstimator
                        print('Loading optional Large depth model...', flush=True)
                        self.server.large_depth = LargeDepthEstimator()
                    candidate = self.server.large_depth
                large_depth = np.asarray(candidate.estimate(image))
                if large_depth.ndim != 2:
                    raise ValueError('Invalid large depth output')
                if large_depth.shape != (h, w):
                    large_depth = cv2.resize(large_depth.astype(np.float32), (w, h), interpolation=cv2.INTER_LINEAR)
            large_finished = time.perf_counter()
            # A compact, frame-aligned raw depth grid permits measuring a clicked
            # point even when the detector has no category for that object.
            grid_w = min(160, w)
            grid_h = max(1, round(h * grid_w / w))
            # The live display uses detection-box distances only. Depth grids
            # are required for the frozen same-frame comparison, so avoid
            # serializing thousands of values on every live camera frame.
            base_grid = None
            if large_depth is not None:
                grid = cv2.resize(depth.astype(np.float32), (grid_w, grid_h), interpolation=cv2.INTER_AREA)
                base_grid = {'width': grid_w, 'height': grid_h,
                             'values': [round(float(v), 3) if math.isfinite(float(v)) and v > 0 else None
                                        for v in grid.ravel()]}
            large_grid = None
            if large_depth is not None:
                large_grid_array = cv2.resize(large_depth.astype(np.float32), (grid_w, grid_h), interpolation=cv2.INTER_AREA)
                large_grid = {'width': grid_w, 'height': grid_h,
                              'values': [round(float(v), 3) if math.isfinite(float(v)) and v > 0 else None
                                         for v in large_grid_array.ravel()]}
            done = time.perf_counter()
            self.json(200, {'width': w, 'height': h, 'detections': out,
                            'depth_grid_large': large_grid,
                            'depth_candidate_name': {'pro': 'Depth Pro', 'large': 'Large', 'mixed': 'Base 混合精度'}[compare_model] if large_grid is not None else None,
                            'depth_candidate_actual': ('mixed' if getattr(candidate, 'use_mixed', False) else 'standard') if large_grid is not None and compare_model == 'mixed' else None,
                            'depth_mode_actual': ('large' if current_depth is self.server.large_depth and self.server.large_depth is not None else 'mixed' if getattr(current_depth, 'use_mixed', False) else 'standard'),
                            'depth_grid': base_grid,
                            'timing_ms': {'decode': round((decoded-start)*1000, 1),
                                          'detection': round((detected-decoded)*1000, 1),
                                          'depth': round((estimated-detected)*1000, 1),
                                          'depth_large': round((large_finished-large_started)*1000, 1) if large_depth is not None else None,
                                          'total': round((done-start)*1000, 1)},
                            'depth_info': 'Estimated camera-axis depth in meters, not a measured distance.'})
        except Exception as exc:
            print(f'Inference failed: {type(exc).__name__}: {exc}', flush=True)
            self.json(500, {'error': 'Inference failed; see local server log'})
        finally:
            self.server.busy.release()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8768)
    args = parser.parse_args()
    # Explicitly bind loopback. Do not expose camera frames to the network.
    from detector import Detector
    from depth import DepthEstimator
    print('Loading local object detection model...', flush=True)
    detector = Detector()
    print('Loading local depth model...', flush=True)
    depth = DepthEstimator()
    with Service(('127.0.0.1', args.port), detector, depth) as server:
        print(f'Ready: http://127.0.0.1:{args.port}/', flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print('\nStopped.', flush=True)


if __name__ == '__main__':
    main()

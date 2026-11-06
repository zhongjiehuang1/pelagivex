#!/usr/bin/env python3
"""Limit an HTTPS tunnel to a single Pelagivex service and secret URL prefix."""
import argparse
import base64
import hmac
import http.client
import json
import os
import threading
import time
from collections import Counter, deque
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

parser = argparse.ArgumentParser()
parser.add_argument('--listen-port', required=True, type=int)
parser.add_argument('--backend-port', required=True, type=int)
parser.add_argument('--token-file', required=True)
parser.add_argument('--metrics-file', help='Optional local-only aggregate metrics file')
parser.add_argument('--preview-port', type=int, help='Optional private loopback-only preview port')
parser.add_argument('--preview-token-file', help='Independent secret for the local preview')
args = parser.parse_args()
token = Path(args.token_file).read_text().strip()
if not 32 <= len(token) <= 128 or not all(c.isalnum() or c in '-_' for c in token):
    raise SystemExit('Invalid access token')
if bool(args.preview_port) != bool(args.preview_token_file):
    raise SystemExit('Preview requires both --preview-port and --preview-token-file')
preview_token = None
if args.preview_port:
    preview_token = Path(args.preview_token_file).read_text().strip()
    if (not 1024 <= args.preview_port <= 65535 or
            not 32 <= len(preview_token) <= 128 or
            not all(c.isalnum() or c in '-_' for c in preview_token) or
            hmac.compare_digest(preview_token, token)):
        raise SystemExit('Invalid private preview configuration')

ALLOWED_GET = {'', 'index.html', 'style.css', 'app.js', 'live.js', 'assets/sample.jpg', 'api/health'}
MAX_BODY = 8_519_680

# Metrics contain aggregate timings and detection counts only: never retain the
# uploaded frame, detection coordinates, client address, token, or request URL.
metrics_lock = threading.Lock()
completions = deque(maxlen=300)
status_counts = Counter()
last_write = 0.0
total_frames = 0
preview_lock = threading.Lock()
preview = {'image': None, 'mime': None, 'detections': None, 'sampled_at': 0.0}
PREVIEW_TTL = 3.0

def record_preview(status, payload, body, content_type):
    if not preview_token or status != 200:
        return
    now = time.monotonic()
    with preview_lock:
        if now - preview['sampled_at'] < 1.0:
            return
        preview['sampled_at'] = now
    try:
        result = json.loads(payload)
        detections = result.get('detections')
        if not isinstance(detections, list):
            return
        message = BytesParser(policy=policy.default).parsebytes(
            b'Content-Type: ' + content_type.encode('ascii') + b'\r\nMIME-Version: 1.0\r\n\r\n' + body)
        if not message.is_multipart():
            return
        for part in message.iter_parts():
            if part.get_param('name', header='content-disposition') != 'image':
                continue
            mime = part.get_content_type().lower()
            image = part.get_payload(decode=True)
            if mime not in ('image/jpeg', 'image/png') or not image or len(image) > 2_000_000:
                return
            with preview_lock:
                preview.update(image=image, mime=mime, detections=detections, sampled_at=time.monotonic())
            return
    except (ValueError, TypeError, UnicodeError, AttributeError):
        return

def expire_preview():
    while True:
        time.sleep(1)
        with preview_lock:
            if preview['image'] is not None and time.monotonic() - preview['sampled_at'] > PREVIEW_TTL:
                preview.update(image=None, mime=None, detections=None)

PREVIEW_HTML = '''<!doctype html><meta name="referrer" content="no-referrer">
<title>Pelagivex local private preview</title>
<style>body{margin:20px;background:#07161a;color:#e8f4f2;font:16px system-ui}canvas{max-width:100%;height:auto}p{color:#9bb}</style>
<h1>Private local preview</h1><p>Latest analyzed frame; clears shortly after capture stops.</p>
<canvas id="frame"></canvas><p id="status">Waiting for an analyzed frame...</p>
<script>
let busy=false;const c=document.getElementById('frame'),ctx=c.getContext('2d'),s=document.getElementById('status');
async function tick(){if(busy)return;busy=true;try{const r=await fetch('frame',{cache:'no-store'});if(r.status===204){ctx.clearRect(0,0,c.width,c.height);s.textContent='Waiting for an analyzed frame...';return;}if(!r.ok)throw Error();const v=await r.json();const im=new Image();im.src='data:'+v.mime+';base64,'+v.image;await im.decode();c.width=im.width;c.height=im.height;ctx.drawImage(im,0,0);ctx.lineWidth=Math.max(2,im.width*.004);ctx.strokeStyle='#47f3ce';ctx.fillStyle='#47f3ce';ctx.font=Math.max(14,im.width*.025)+'px system-ui';for(const d of v.detections){const b=d.box;if(!Array.isArray(b)||b.length!==4||!b.every(Number.isFinite))continue;ctx.strokeRect(b[0],b[1],b[2]-b[0],b[3]-b[1]);ctx.fillText('gate '+Math.round(d.confidence*100)+'%',Math.max(0,b[0]),Math.max(20,b[1]-4));}s.textContent='Latest analyzed frame · '+v.detections.length+' detection(s)';}catch(e){ctx.clearRect(0,0,c.width,c.height);s.textContent='Preview unavailable';}finally{busy=false;}}
tick();setInterval(tick,500);
</script>'''.encode('utf-8')

class PreviewHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass
    def do_GET(self):
        expected_host = '127.0.0.1:' + str(args.preview_port)
        origin = self.headers.get('Origin')
        if self.headers.get('Host') != expected_host or (origin and origin != 'http://' + expected_host):
            return self.send_empty(404)
        path = urlsplit(self.path).path.split('/', 2)
        if len(path) != 3 or not hmac.compare_digest(path[1], preview_token):
            return self.send_empty(404)
        if path[2] == '':
            return self.send_payload(200, 'text/html; charset=utf-8', PREVIEW_HTML)
        if path[2] != 'frame':
            return self.send_empty(404)
        with preview_lock:
            if preview['image'] is None or time.monotonic() - preview['sampled_at'] > PREVIEW_TTL:
                return self.send_empty(204)
            data = json.dumps({'image': base64.b64encode(preview['image']).decode('ascii'),
                               'mime': preview['mime'], 'detections': preview['detections']},
                              separators=(',', ':')).encode('utf-8')
        self.send_payload(200, 'application/json', data)
    def send_empty(self, code):
        self.send_payload(code, 'text/plain', b'')
    def send_payload(self, code, content_type, data):
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store, private')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('Content-Security-Policy', "default-src 'self'; img-src 'self' data:; script-src 'unsafe-inline'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'")
        self.end_headers()
        if data:
            self.wfile.write(data)

def record_metrics(status, payload, started):
    global total_frames, last_write
    if not args.metrics_file:
        return
    now = time.time()
    elapsed = round((time.monotonic() - started) * 1000, 1)
    model_ms = None
    detections = None
    if status == 200:
        try:
            result = json.loads(payload)
            model_ms = result.get('duration_ms')
            detection_list = result.get('detections')
            detections = len(detection_list) if isinstance(detection_list, list) else None
        except (ValueError, TypeError, AttributeError):
            pass
    with metrics_lock:
        status_counts[str(status)] += 1
        if status == 200:
            total_frames += 1
            completions.append(now)
        recent = [t for t in completions if now - t <= 10]
        if now - last_write < 1.0:
            return
        snapshot = {
            'updated_epoch': now,
            'last_status': status,
            'successful_frames': total_frames,
            'status_counts': dict(status_counts),
            'last_proxy_ms': elapsed,
            'last_model_ms': model_ms,
            'last_detection_count': detections,
            'recent_fps': round((len(recent) - 1) / (recent[-1] - recent[0]), 2)
                if len(recent) > 1 and recent[-1] > recent[0] else None,
            'recent_window_frames': len(recent),
        }
        try:
            path = Path(args.metrics_file)
            tmp = path.with_name(path.name + '.next')
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, 'w') as out:
                json.dump(snapshot, out, separators=(',', ':'))
            os.replace(tmp, path)
            last_write = now
        except OSError:
            # An unavailable metrics file must never stop live inference.
            pass

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, fmt, *args):
        pass  # URL includes the access token; never log requests.
    def fail(self, status):
        self.send_response(status)
        self.send_header('Content-Length', '0')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.end_headers()
        self.close_connection = True
    def do_GET(self): self.forward('GET')
    def do_HEAD(self): self.forward('HEAD')
    def do_POST(self): self.forward('POST')
    def forward(self, method):
        started = time.monotonic()
        parts = urlsplit(self.path)
        pieces = parts.path.split('/', 2)
        if len(pieces) != 3 or not hmac.compare_digest(pieces[1], token):
            return self.fail(404)
        route = pieces[2]
        if ((method in ('GET', 'HEAD') and route not in ALLOWED_GET) or
                (method == 'POST' and route != 'api/detect')):
            return self.fail(404)
        headers = {}
        body = None
        if method == 'POST':
            if self.headers.get('Transfer-Encoding'):
                return self.fail(400)
            try:
                size = int(self.headers.get('Content-Length', '-1'))
            except ValueError:
                return self.fail(400)
            if size < 0 or size > MAX_BODY:
                return self.fail(413)
            content_type = self.headers.get('Content-Type', '')
            if not content_type.lower().startswith('multipart/form-data;'):
                return self.fail(400)
            self.connection.settimeout(20)
            try:
                body = self.rfile.read(size)
            except OSError:
                return self.fail(408)
            if len(body) != size:
                return self.fail(400)
            headers['Content-Type'] = content_type
        connection = http.client.HTTPConnection('127.0.0.1', args.backend_port, timeout=30)
        try:
            path = '/' + route + ('?' + parts.query if parts.query else '')
            connection.request(method, path, body=body, headers=headers)
            result = connection.getresponse()
            payload = result.read()
            if method == 'POST' and route == 'api/detect':
                record_preview(result.status, payload, body, headers.get('Content-Type', ''))
            self.send_response(result.status)
            content_type = result.getheader('Content-Type')
            if content_type:
                self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', result.getheader('Content-Length', '0') if method == 'HEAD' else str(len(payload)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('X-Frame-Options', 'DENY')
            self.send_header('Permissions-Policy', 'camera=(self), microphone=()')
            self.send_header('Content-Security-Policy', "default-src 'self'; img-src 'self' blob: data:; media-src 'self' blob:; object-src 'none'; base-uri 'self'; frame-ancestors 'none'")
            self.end_headers()
            if method != 'HEAD':
                self.wfile.write(payload)
            if method == 'POST' and route == 'api/detect':
                record_metrics(result.status, payload, started)
        except (OSError, http.client.HTTPException):
            if method == 'POST' and route == 'api/detect':
                record_metrics(502, b'', started)
            self.fail(502)
        finally:
            connection.close()

class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

if preview_token:
    preview_server = Server(('127.0.0.1', args.preview_port), PreviewHandler)
    threading.Thread(target=preview_server.serve_forever, daemon=True).start()
    threading.Thread(target=expire_preview, daemon=True).start()
Server(('127.0.0.1', args.listen_port), Handler).serve_forever()

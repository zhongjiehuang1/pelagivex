#!/usr/bin/env python3
"""Isolated, opt-in Pelagivex WS prototype. Not wired to the production proxy."""
import argparse
import asyncio
import hmac
import http.client
import json
import logging
import struct
from pathlib import Path
from urllib.parse import urlsplit
from websockets.asyncio.server import serve

MAX_JPEG = 8_388_608
MAX_ID = (1 << 53) - 1
BOUNDARY = 'PelagivexWsFrameBoundary9c6b'
LOG = logging.getLogger('pelagivex.private.ws')
LOG.addHandler(logging.NullHandler())
LOG.propagate = False


def infer_on_http(frame, backend_port):
    """Call validated HTTP backend; this proxy does not persist frame bytes."""
    start = (f'--{BOUNDARY}\r\nContent-Disposition: form-data; name="image"; filename="frame.jpg"\r\n'
             'Content-Type: image/jpeg\r\n\r\n').encode('ascii')
    end = f'\r\n--{BOUNDARY}--\r\n'.encode('ascii')
    conn = http.client.HTTPConnection('127.0.0.1', backend_port, timeout=30)
    try:
        conn.request('POST', '/api/detect', body=start + frame + end,
                     headers={'Content-Type': 'multipart/form-data; boundary=' + BOUNDARY})
        response = conn.getresponse()
        body = response.read(1_048_577)
        if response.status != 200:
            return response.status, None
        if len(body) > 1_048_576:
            return 502, None
        data = json.loads(body)
        if not isinstance(data, dict) or not isinstance(data.get('detections'), list):
            return 502, None
        return 200, data
    except (OSError, ValueError, http.client.HTTPException):
        return 502, None
    finally:
        conn.close()


def make_server(token, origin, backend_port, workers=1):
    if not 1 <= workers <= 4:
        raise ValueError('workers must be between 1 and 4')
    if not (32 <= len(token) <= 128 and all(c.isalnum() or c in '-_' for c in token)):
        raise ValueError('Invalid token')
    expected = '/' + token + '/api/stream'
    active = set()

    async def process_request(connection, request):
        # Avoid exposing presence of the endpoint or logging the URL token.
        if not hmac.compare_digest(urlsplit(request.path).path, expected):
            return connection.respond(404, 'Not found\n')
        if len(active) >= 1:
            return connection.respond(503, 'Busy\n')
        return None

    async def handle(ws):
        # The handshake runs on one event loop: the second check closes the
        # small gap between two simultaneous handshake callbacks.
        if active:
            await ws.close(1013, 'Busy')
            return
        active.add(ws)
        queue = asyncio.Queue(maxsize=1)
        last_id = -1

        async def send(obj):
            await ws.send(json.dumps(obj, separators=(',', ':')))

        async def worker():
            while True:
                frame_id, frame = await queue.get()
                try:
                    # Cancellation cannot stop a running HTTP request; keep the
                    # slot reserved until that request completes, so reconnects
                    # cannot exceed the configured total inference concurrency.
                    inference = asyncio.create_task(asyncio.to_thread(infer_on_http, frame, backend_port))
                    try:
                        status, data = await asyncio.shield(inference)
                    except asyncio.CancelledError:
                        try:
                            await inference
                        except Exception:
                            pass
                        raise
                    if status == 200:
                        await send({'type': 'result', 'id': frame_id, 'data': data})
                    else:
                        await send({'type': 'error', 'id': frame_id, 'status': status})
                finally:
                    queue.task_done()

        tasks = [asyncio.create_task(worker()) for _ in range(workers)]
        try:
            async for message in ws:
                if not isinstance(message, bytes) or len(message) < 10:
                    await ws.close(1003, 'Expected binary JPEG frame')
                    break
                frame_id = struct.unpack('>Q', message[:8])[0]
                frame = message[8:]
                if frame_id > MAX_ID or frame_id <= last_id or not frame.startswith(b'\xff\xd8'):
                    await ws.close(1008, 'Invalid frame')
                    break
                last_id = frame_id
                if queue.full():
                    dropped_id, _ = queue.get_nowait()
                    queue.task_done()
                    await send({'type': 'dropped', 'id': dropped_id})
                await queue.put((frame_id, frame))
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            while not queue.empty():
                queue.get_nowait()
                queue.task_done()
            active.discard(ws)

    def serve_at(host, port):
        return serve(handle, host, port, origins=[origin], process_request=process_request,
                     max_size=MAX_JPEG + 8, max_queue=1, compression=None,
                     ping_interval=20, ping_timeout=20, open_timeout=10,
                     close_timeout=2, server_header=None, logger=LOG)
    return serve_at


async def run(args):
    token = Path(args.token_file).read_text().strip()
    origin = args.origin
    if not origin.startswith('https://') or '/' in origin[8:]:
        raise ValueError('Origin must be a precise HTTPS origin')
    server = make_server(token, origin, args.backend_port, args.workers)
    async with server('127.0.0.1', args.port):
        print('Private WS prototype listening on 127.0.0.1:' + str(args.port), flush=True)
        await asyncio.Future()

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--workers', type=int, choices=(1,2,3,4), default=1)
    p.add_argument('--port', type=int, required=True)
    p.add_argument('--backend-port', type=int, required=True)
    p.add_argument('--token-file', required=True)
    p.add_argument('--origin', required=True)
    asyncio.run(run(p.parse_args()))

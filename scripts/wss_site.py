#!/usr/bin/env python3
"""Private token-protected WSS site; local bind only, no frame persistence."""
import argparse
import asyncio
import hmac
from pathlib import Path
from urllib.parse import urlsplit
import wss_stream

PROJECT = Path(__file__).resolve().parents[1]
ORIGIN = 'https://pelagivex.zhongjiehuang.com'
ASSETS = {'': ('index.html', 'text/html; charset=utf-8'),
          'client.js': ('client.js', 'application/javascript; charset=utf-8'),
          'mobile.js': ('mobile.js', 'application/javascript; charset=utf-8'),
          'mobile.css': ('mobile.css', 'text/css; charset=utf-8')}

async def run(args):
    token = Path(args.token_file).read_text().strip()
    ws_server = wss_stream.make_server(token, ORIGIN, args.backend_port, workers=args.workers)('127.0.0.1', args.port)
    original = ws_server.server.process_request
    async def route(connection, request):
        path = urlsplit(request.path).path
        parts = path.split('/', 2)
        if len(parts) != 3 or not hmac.compare_digest(parts[1], token):
            return connection.respond(404, 'Not found\n')
        if parts[2] in ASSETS:
            name, content_type = ASSETS[parts[2]]
            try:
                data = (PROJECT / 'web/wss' / name).read_bytes()
            except OSError:
                return connection.respond(503, 'Asset unavailable\n')
            response = connection.respond(200, '')
            response.body = data
            for header in ('Content-Length', 'Content-Type'):
                if header in response.headers: del response.headers[header]
            response.headers['Content-Length'] = str(len(data))
            response.headers['Content-Type'] = content_type
            response.headers['Cache-Control'] = 'no-store, private'
            response.headers['Referrer-Policy'] = 'no-referrer'
            response.headers['X-Content-Type-Options'] = 'nosniff'
            response.headers['X-Frame-Options'] = 'DENY'
            response.headers['Permissions-Policy'] = 'camera=(self), microphone=()'
            response.headers['Content-Security-Policy'] = (
                "default-src 'self'; connect-src 'self' wss://pelagivex.zhongjiehuang.com; "
                "img-src 'self' data: blob:; media-src 'self' blob:; object-src 'none'; "
                "base-uri 'self'; frame-ancestors 'none'")
            return response
        return await original(connection, request)
    ws_server.server.process_request = route
    async with ws_server:
        print('Pelagivex WSS local site ready on 127.0.0.1:' + str(args.port), flush=True)
        await asyncio.Future()

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--workers', type=int, choices=(1, 2, 3, 4), default=1)
    p.add_argument('--port', type=int, required=True)
    p.add_argument('--backend-port', type=int, required=True)
    p.add_argument('--token-file', required=True)
    args = p.parse_args()
    asyncio.run(run(args))

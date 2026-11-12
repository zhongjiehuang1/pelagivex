#!/usr/bin/env python3
"""Private LAN WebRTC endpoint for the Pelagivex mobile demo.

Signaling is served on loopback through the authenticated HTTPS tunnel. Camera
frames and model results travel over the encrypted WebRTC channel. No images,
coordinates, SDP, token, or addresses are written to logs or files.
"""
import asyncio
import hashlib
import ipaddress
import json
import os
import struct
import time
from collections import deque
from pathlib import Path

import aioice.ice
from aiohttp import ClientSession, FormData, web
from aiortc import RTCConfiguration, RTCPeerConnection, RTCSessionDescription

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'web' / 'lan-stage'
TOKEN = Path(os.environ['PELAGIVEX_RTC_TOKEN_FILE']).read_text().strip()
if len(TOKEN) < 32 or not all(c.isalnum() or c in '-_' for c in TOKEN):
    raise SystemExit('Invalid access token')
PORT = int(os.environ.get('PELAGIVEX_RTC_HTTP_PORT', '18713'))
BACKEND_PORT = int(os.environ.get('PELAGIVEX_RTC_BACKEND_PORT', '18707'))
if not all(1024 <= p <= 65535 for p in (PORT, BACKEND_PORT)):
    raise SystemExit('Invalid port')
bind_ip = str(ipaddress.IPv4Address(os.environ['PELAGIVEX_RTC_BIND_IP']))
# Restrict the UDP host candidate to the user's selected Wi-Fi interface.
aioice.ice.get_host_addresses = lambda use_ipv4, use_ipv6: [bind_ip] if use_ipv4 else []
BACKEND = f'http://127.0.0.1:{BACKEND_PORT}/api/detect'
MAX_FRAME = 2_000_000
CHUNK = 16_000
PEERS = set()
COMPLETIONS = deque(maxlen=300)
METRICS = os.environ.get('PELAGIVEX_RTC_METRICS_FILE')
INSTANCE = os.environ.get('PELAGIVEX_RTC_INSTANCE', '')
STATS = {'successful': 0, 'dropped': 0, 'last_written': 0.0}


def record(result, source):
    now = time.time()
    STATS['successful'] += 1
    COMPLETIONS.append(now)
    if not METRICS or now - STATS['last_written'] < 1:
        return
    recent = [t for t in COMPLETIONS if now - t <= 10]
    summary = {'updated_epoch': now, 'source': source,
               'successful_frames': STATS['successful'], 'dropped_frames': STATS['dropped'],
               'last_model_ms': result.get('duration_ms'),
               'last_detection_count': len(result.get('detections', [])),
               'recent_fps': round((len(recent)-1)/(recent[-1]-recent[0]), 2)
                   if len(recent)>1 and recent[-1]>recent[0] else None}
    path = Path(METRICS)
    tmp = path.with_name(path.name + '.next')
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as output:
            json.dump(summary, output, separators=(',', ':'))
        os.replace(tmp, path)
        STATS['last_written'] = now
    except OSError:
        pass


def safe_origin(request):
    return request.headers.get('Origin', '') in (
        'https://pelagivex.zhongjiehuang.com', f'http://127.0.0.1:{PORT}')


async def detect(payload):
    form = FormData()
    form.add_field('image', payload, filename='frame.jpg', content_type='image/jpeg')
    try:
        async with ClientSession() as session:
            async with session.post(BACKEND, data=form, timeout=10) as response:
                if response.status != 200:
                    return None
                return await response.json()
    except (OSError, ValueError, asyncio.TimeoutError):
        return None


async def index(request):
    headers = {'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer',
               'X-Content-Type-Options': 'nosniff', 'X-Frame-Options': 'DENY',
               'Permissions-Policy': 'camera=(self), microphone=()',
               'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; media-src 'self' blob:; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'"}
    return web.Response(text=(ASSETS/'index.html').read_text(), content_type='text/html', headers=headers)


async def static(request):
    name = request.match_info['name']
    if name not in ('stage.js', 'stage.css'):
        return web.Response(status=404)
    return web.FileResponse(ASSETS/name, headers={'Cache-Control':'no-store','Referrer-Policy':'no-referrer'})


async def health(request):
    return web.json_response({'status': 'ok', 'instance': INSTANCE}, headers={'Cache-Control':'no-store'})


def lan_sdp(sdp):
    """Retain only LAN-capable UDP host candidates; do not probe others.

    Safari may include TCP or public IPv6 host candidates alongside valid
    private candidates. Dropping the unsupported alternatives, rather than
    rejecting the whole offer, keeps local discovery working safely.
    """
    kept = []
    accepted = 0
    for line in sdp.splitlines():
        if line.startswith('a=remote-candidates:'):
            continue
        if not line.startswith('a=candidate:'):
            kept.append(line)
            continue
        fields = line.split()
        if len(fields)<8 or fields[2].lower()!='udp' or fields[7]!='host':
            continue
        address = fields[4].rstrip('.').lower()
        if address.endswith('.local'):
            kept.append(line)
            accepted += 1
            continue
        try:
            candidate = ipaddress.ip_address(address)
        except ValueError:
            continue
        if candidate.is_loopback or candidate.is_multicast or candidate.is_unspecified:
            continue
        if not candidate.is_private and not (candidate.version==4 and candidate in ipaddress.ip_network('100.64.0.0/10')):
            continue
        kept.append(line)
        accepted += 1
    return ('\r\n'.join(kept)+'\r\n') if accepted else None


async def offer(request):
    if not safe_origin(request):
        return web.Response(status=403)
    if PEERS:
        return web.Response(status=429)
    try:
        data = await request.json()
        sdp = data.get('sdp')
        if data.get('type')!='offer' or not isinstance(sdp,str) or len(sdp)>30000:
            return web.json_response({'error':'invalid_offer'},status=400)
        sdp = lan_sdp(sdp)
        if sdp is None:
            return web.json_response({'error':'no_lan_candidate'},status=400)
    except (ValueError, AttributeError):
        return web.json_response({'error':'invalid_offer'},status=400)
    # A concurrent request may have passed the first check while JSON was read.
    if PEERS:
        return web.Response(status=429)
    pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
    PEERS.add(pc)
    active = None
    newest = None
    assembly = None
    channel = None

    async def expire():
        await asyncio.sleep(60)
        if pc.connectionState != 'connected':
            await pc.close()
            PEERS.discard(pc)
    asyncio.create_task(expire())

    async def process(item):
        nonlocal active, newest
        try:
            while item is not None:
                ident, payload = item
                result = await detect(payload)
                if result is None:
                    if channel and channel.readyState=='open':
                        channel.send(json.dumps({'type':'busy','id':ident}))
                    break
                record(result,'webrtc')
                if channel and channel.readyState=='open':
                    channel.send(json.dumps({'type':'result','id':ident,
                                             'sha256':hashlib.sha256(payload).hexdigest(),'data':result}))
                item, newest = newest, None
        finally:
            active = None
            newest = None

    @pc.on('connectionstatechange')
    async def state():
        if pc.connectionState in ('failed','closed'):
            await pc.close()
            PEERS.discard(pc)

    @pc.on('datachannel')
    def on_channel(ch):
        nonlocal channel
        if channel is not None or ch.label != 'frames':
            ch.close()
            return
        channel = ch
        @ch.on('close')
        def close_channel():
            asyncio.create_task(pc.close())
            PEERS.discard(pc)

        @ch.on('message')
        def on_message(msg):
            nonlocal assembly, active, newest
            if not isinstance(msg,bytes) or not 12<=len(msg)<=CHUNK+12:
                return
            ident, part, total = struct.unpack('!QHH', msg[:12])
            if not 0<ident<=9007199254740991 or not 1<=total<=126 or part>=total:
                return
            if part == 0:
                assembly = [ident,total,[],0]
            if not assembly or ident!=assembly[0] or total!=assembly[1] or part!=len(assembly[2]):
                return
            body = msg[12:]
            assembly[2].append(body)
            assembly[3] += len(body)
            if assembly[3] > MAX_FRAME:
                assembly = None
                return
            if part+1 == total:
                item = (ident,b''.join(assembly[2]))
                assembly = None
                if active is None:
                    active = asyncio.create_task(process(item))
                else:
                    if newest is not None and ch.readyState=='open':
                        STATS['dropped'] += 1
                        ch.send(json.dumps({'type':'dropped','id':newest[0]}))
                    newest = item
    try:
        await pc.setRemoteDescription(RTCSessionDescription(sdp=sdp,type='offer'))
        answer = await pc.createAnswer()
        await pc.setLocalDescription(answer)
        return web.json_response({'type':pc.localDescription.type,'sdp':pc.localDescription.sdp},
                                 headers={'Cache-Control':'no-store','Referrer-Policy':'no-referrer'})
    except Exception:
        await pc.close()
        PEERS.discard(pc)
        return web.json_response({'error':'invalid_sdp'},status=400)


async def http_detect(request):
    if not safe_origin(request):
        return web.Response(status=403)
    try:
        reader = await request.multipart()
        part = await reader.next()
        if not part or part.name!='image':
            return web.Response(status=400)
        chunks=[]
        size=0
        while True:
            chunk = await part.read_chunk(size=16384)
            if not chunk:
                break
            size += len(chunk)
            if size > MAX_FRAME:
                return web.Response(status=413)
            chunks.append(chunk)
        result = await detect(b''.join(chunks))
        if result is None:
            return web.Response(status=429)
        record(result,'http')
        return web.json_response(result, headers={'Cache-Control':'no-store'})
    except (ValueError,AssertionError):
        return web.Response(status=400)


async def on_shutdown(app):
    await asyncio.gather(*(p.close() for p in list(PEERS)),return_exceptions=True)


app = web.Application(client_max_size=MAX_FRAME)
app.router.add_get('/'+TOKEN+'/', index)
app.router.add_get('/'+TOKEN+'/health', health)
app.router.add_get('/'+TOKEN+'/{name:stage\\.(?:js|css)}', static)
app.router.add_post('/'+TOKEN+'/offer', offer)
app.router.add_post('/'+TOKEN+'/detect', http_detect)
app.on_shutdown.append(on_shutdown)
if __name__ == '__main__':
    print(f'LAN signaling listening on 127.0.0.1:{PORT}', flush=True)
    web.run_app(app,host='127.0.0.1',port=PORT,print=None,access_log=None)

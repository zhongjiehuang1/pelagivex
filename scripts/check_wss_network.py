#!/usr/bin/env python3
"""Verify demo HTTPS and WSS without exposing its token in process arguments.

When the system resolver fails, a public DNS lookup is accepted only if it
returns the same server IP used by the SSH tunnel. TLS hostname verification
and the original HTTP Host header remain enabled in the fallback.
"""
import argparse
import asyncio
import http.client
import socket
import ssl
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit
import certifi
from websockets.asyncio.client import connect

HOST='pelagivex.zhongjiehuang.com'
EXPECTED_ADDRESS='8.211.120.109'
ORIGIN='https://' + HOST

class ResolvedHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, host, address, context):
        super().__init__(host, 443, timeout=10, context=context)
        self.address=address
    def connect(self):
        raw=socket.create_connection((self.address,443),timeout=self.timeout)
        try:
            self.sock=self._context.wrap_socket(raw,server_hostname=self.host)
        except BaseException:
            raw.close()
            raise

def resolve_known_address():
    for resolver in ('1.1.1.1','8.8.8.8'):
        try:
            result=subprocess.run(['/usr/bin/dig','@'+resolver,'+time=2','+tries=1',
                                   '+short',HOST,'A'],capture_output=True,text=True,timeout=4,check=False)
        except (OSError,subprocess.TimeoutExpired):
            continue
        if EXPECTED_ADDRESS in result.stdout.split():
            return EXPECTED_ADDRESS
    raise OSError('Public DNS did not return the configured server address')

def get_page(token, context, address=None, local_port=None):
    if local_port is not None:
        conn=http.client.HTTPConnection('127.0.0.1',local_port,timeout=10)
        path='/' + token + '/'
    else:
        conn=(ResolvedHTTPSConnection(HOST,address,context) if address else
              http.client.HTTPSConnection(HOST,443,timeout=10,context=context))
        path='/mac-ws/' + token + '/'
    try:
        conn.request('GET',path,headers={'Cache-Control':'no-store'})
        resp=conn.getresponse()
        resp.read()
        if resp.status != 200:raise OSError('Demo page returned a non-200 response')
    finally:
        conn.close()

async def verify(token, local_port=None):
    context=ssl.create_default_context(cafile=certifi.where())
    # Never bypass certificate verification, even when connecting to a resolved IP.
    if not context.check_hostname or context.verify_mode != ssl.CERT_REQUIRED:
        raise RuntimeError('TLS hostname verification must be enabled')
    address=None
    try:
        get_page(token,context,local_port=local_port)
    except socket.gaierror:
        if local_port is not None:raise
        address=resolve_known_address()
        get_page(token,context,address=address)
    path=('/' + token + '/') if local_port is not None else ('/mac-ws/' + token + '/')
    authority=('127.0.0.1:' + str(local_port)) if local_port is not None else HOST
    uri=('ws://' if local_port is not None else 'wss://') + authority + path + 'api/stream'
    options={'origin':ORIGIN,'proxy':None,'open_timeout':10}
    if local_port is None:
        options['ssl']=context
        if address:
            options.update(host=address,port=443,server_hostname=HOST)
    try:
        async with connect(uri,**options):pass
    except socket.gaierror:
        if local_port is not None or address:raise
        address=resolve_known_address()
        options.update(host=address,port=443,server_hostname=HOST)
        async with connect(uri,**options):pass
    return bool(address)

def main():
    p=argparse.ArgumentParser();p.add_argument('--token-file',required=True)
    p.add_argument('--local-port',type=int)
    args=p.parse_args(); token=Path(args.token_file).read_text().strip()
    if not (32<=len(token)<=128 and all(c.isalnum() or c in '-_' for c in token)):
        raise SystemExit('Invalid token')
    try:
        fallback=asyncio.run(verify(token,args.local_port))
    except Exception as exc:
        # Exception text can contain a token-bearing URL: do not print it.
        print('HTTPS/WSS 验证失败：'+type(exc).__name__,file=sys.stderr)
        return 1
    if fallback: print('本机 DNS 暂未更新，已通过独立解析并验证原域名的 TLS 证书；手机解析可能不同。')
    return 0
if __name__=='__main__':sys.exit(main())

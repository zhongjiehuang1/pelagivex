#!/usr/bin/env python3
"""Restore checksum-pinned published runtime assets without replacing local changes."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import ssl
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def destination(relative):
    name = PurePosixPath(relative)
    if name.is_absolute() or '..' in name.parts:
        raise ValueError('Invalid artifact path')
    path = ROOT.joinpath(*name.parts)
    if not path.resolve().is_relative_to(ROOT.resolve()):
        raise ValueError('Artifact destination escapes checkout')
    return path


def install(stream, relative, expected, mode=0o644):
    path = destination(relative)
    if path.exists():
        if path.is_file() and digest(path) == expected:
            return
        raise ValueError('Existing file differs; preserve it before restoring: ' + relative)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.download')
    try:
        with temporary.open('xb') as output:
            shutil.copyfileobj(stream, output)
        if digest(temporary) != expected:
            raise ValueError('Extracted file checksum mismatch: ' + relative)
        temporary.chmod(mode & 0o777)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def download(item, cache):
    path = cache / item['name']
    if path.is_file() and path.stat().st_size == item['bytes'] and digest(path) == item['sha256']:
        return path
    temporary = path.with_name(path.name + '.partial')
    # Python.org macOS installs sometimes need the operating system CA bundle.
    ca_file = '/etc/ssl/cert.pem' if Path('/etc/ssl/cert.pem').is_file() else None
    context = ssl.create_default_context(cafile=ca_file)
    try:
        request = urllib.request.Request(item['url'], headers={'User-Agent': 'PelagiVex-runtime-restore'})
        with urllib.request.urlopen(request, context=context, timeout=60) as response, temporary.open('wb') as output:
            shutil.copyfileobj(response, output, 1024 * 1024)
        if temporary.stat().st_size != item['bytes'] or digest(temporary) != item['sha256']:
            raise ValueError('Downloaded artifact checksum mismatch: ' + item['name'])
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    return path


def restore(item, cache):
    archive = download(item, cache)
    entries = {entry['path']: entry for entry in item['installedFiles']}
    if item['format'] == 'file':
        entry = next(iter(entries.values()))
        with archive.open('rb') as source:
            install(source, entry['path'], entry['sha256'])
    elif item['format'] == 'tar.gz':
        with tarfile.open(archive, 'r:gz') as source:
            for member in source:
                if member.isdir():
                    continue
                if not member.isfile() or member.name not in entries:
                    raise ValueError('Unexpected archive entry')
                entry = entries[member.name]
                with source.extractfile(member) as content:
                    install(content, member.name, entry['sha256'], entry.get('mode', 0o644))
    elif item['format'] == 'zip':
        prefix = item['destinationPrefix']
        with zipfile.ZipFile(archive) as source:
            for member in source.infolist():
                if member.is_dir():
                    continue
                relative = prefix + '/' + member.filename
                if relative not in entries or (member.external_attr >> 16) & 0o170000 == 0o120000:
                    raise ValueError('Unexpected ZIP entry')
                entry = entries[relative]
                with source.open(member) as content:
                    install(content, relative, entry['sha256'], entry.get('mode', 0o644))
    else:
        raise ValueError('Unsupported artifact format')
    verify(item)


def verify(item):
    for entry in item['installedFiles']:
        path = destination(entry['path'])
        if not path.is_file() or path.stat().st_size != entry['bytes'] or digest(path) != entry['sha256']:
            raise ValueError('Runtime file missing or changed: ' + entry['path'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release', action='store_true', help='Restore application, Core ML bundles and trained gate model')
    parser.add_argument('--official-models', action='store_true', help='Restore pinned OWLv2, SAM and metric-depth weights from upstream')
    parser.add_argument('--verify-only', action='store_true', help='Verify installed files without downloading or writing')
    args = parser.parse_args()
    if not args.release and not args.official_models:
        parser.error('Choose --release and/or --official-models')
    manifest = json.loads((ROOT / 'runtime-assets.json').read_text())
    selected = (manifest['releaseAssets'] if args.release else []) + (manifest['officialModels'] if args.official_models else [])
    cache = ROOT / '.cache/release-assets'
    if not args.verify_only:
        cache.mkdir(parents=True, exist_ok=True)
    for item in selected:
        if args.verify_only:
            verify(item)
        else:
            restore(item, cache)
        print('Verified:', item['name'])


if __name__ == '__main__':
    main()

"""Fetch two named DAVIS validation sequences from the official ZIP using byte ranges.

Retains annotations and RGB images, checks ZIP CRC, and records per-file SHA-256.
No third-party mirror or full 833 MB archive is required.
"""
import argparse
import concurrent.futures
import hashlib
import io
import json
from pathlib import Path
import struct
import ssl
import certifi
import urllib.request
import zipfile
import zlib

URL = "https://data.vision.ee.ethz.ch/csergi/share/davis/DAVIS-2017-trainval-480p.zip"
TLS = ssl.create_default_context(cafile=certifi.where())


class Remote(io.RawIOBase):
    def __init__(self):
        with urllib.request.urlopen(urllib.request.Request(URL, method="HEAD"), timeout=30, context=TLS) as response:
            self.size = int(response.headers["Content-Length"])
        self.position = 0

    def seek(self, offset, whence=0):
        self.position = offset + (self.position if whence == 1 else self.size if whence == 2 else 0)
        return self.position

    def tell(self):
        return self.position

    def read(self, size=-1):
        if size < 0:
            size = self.size - self.position
        if not size:
            return b""
        data = fetch(self.position, self.position + size - 1)
        self.position += len(data)
        return data


def fetch(first, last):
    request = urllib.request.Request(URL, headers={"Range": f"bytes={first}-{last}"})
    with urllib.request.urlopen(request, timeout=40, context=TLS) as response:
        if response.status != 206:
            raise RuntimeError("Server did not honor the byte range; refusing full archive download.")
        return response.read()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path(".cache/contour-research/davis"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    sequences = ("blackswan", "dance-twirl")
    with zipfile.ZipFile(Remote()) as archive:
        entries = [entry for entry in archive.infolist()
                   if any(f"/{kind}/480p/{sequence}/" in entry.filename
                          for kind in ("JPEGImages", "Annotations") for sequence in sequences)
                   and not entry.is_dir()]
    if not entries:
        raise RuntimeError("Requested official sequence names were absent.")

    def extract(entry):
        relative = Path(entry.filename)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Unsafe ZIP path")
        destination = args.output / relative
        if not destination.exists():
            # Local header plus file name and optional extra fields precede the compressed bytes.
            header = fetch(entry.header_offset, entry.header_offset + 29)
            signature, *fields = struct.unpack("<4s5H3I2H", header)
            if signature != b"PK\x03\x04":
                raise ValueError("Invalid ZIP local header")
            offset = entry.header_offset + 30 + fields[-2] + fields[-1]
            raw = fetch(offset, offset + entry.compress_size - 1)
            data = zlib.decompress(raw, -15) if entry.compress_type == zipfile.ZIP_DEFLATED else raw
            if len(data) != entry.file_size or zlib.crc32(data) != entry.CRC:
                raise ValueError("ZIP integrity check failed")
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
        data = destination.read_bytes()
        if len(data) != entry.file_size or zlib.crc32(data) != entry.CRC:
            raise ValueError("Cached file integrity check failed")
        return {"path": str(relative), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        records = list(executor.map(extract, entries))
    report = {"officialSource": URL, "sourcePage": "https://davischallenge.org/davis2017/code.html",
              "sequences": sequences, "purpose": "Diagnostic subset, not a full DAVIS benchmark",
              "files": records, "bytes": sum(row["bytes"] for row in records)}
    (args.output / "provenance.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Verified {len(records)} files, {report['bytes']/1e6:.1f} MB")


if __name__ == "__main__":
    main()

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'An Apple Silicon Mac is required.' >&2; exit 1; }
[[ "${1:-}" == --acknowledge-model-license ]] || { echo 'Read https://www.ultralytics.com/license then re-run with --acknowledge-model-license.' >&2; exit 1; }
PY="${PYTHON:-python3.11}"
command -v "$PY" >/dev/null || { echo "Install Python 3.11 or set PYTHON to a Python 3.11/3.12 executable." >&2; exit 1; }
"$PY" -c 'import sys; assert (3,11) <= sys.version_info[:2] <= (3,12), "Python 3.11 or 3.12 required"'
[[ ! -e Model-YOLO11x-seg-768 ]] || { echo 'Model-YOLO11x-seg-768 already exists; choose a new output directory to replace it deliberately.' >&2; exit 1; }
[[ -d .venv-model ]] || "$PY" -m venv .venv-model
.venv-model/bin/python -m pip install -r scripts/requirements-model.txt
.venv-model/bin/python -m pip freeze > .venv-model/installed-versions.txt
.venv-model/bin/python scripts/export_model.py --output Model-YOLO11x-seg-768 --weights yolo11x-seg.pt --size 768 --acknowledge-model-license

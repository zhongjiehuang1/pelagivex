#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd -P)"
PORT="${PELAGIVEX_LOCAL_PORT:-8768}"
if [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1024 || PORT > 65535 )); then
  echo "Invalid PELAGIVEX_LOCAL_PORT" >&2; exit 1
fi
mkdir -p .tmp .cache/local-vision
PID_FILE="$PROJECT_DIR/.tmp/local-vision-$PORT.pid"
LOG_FILE="$PROJECT_DIR/.tmp/local-vision-$PORT.log"
if [[ -f "$PID_FILE" ]]; then
  OLD_PID="$(cat "$PID_FILE")"
  if [[ "$OLD_PID" =~ ^[0-9]+$ ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    OLD_COMMAND="$(ps -p "$OLD_PID" -o command= || true)"
    if [[ "$OLD_COMMAND" == *"local_vision/server.py --port $PORT"* ]]; then
      echo "A local vision process is already running (PID $OLD_PID)."
      echo "http://127.0.0.1:$PORT/"
      exit 0
    fi
  fi
fi
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is already in use; choose PELAGIVEX_LOCAL_PORT." >&2; exit 1
fi
[[ -x .venv-model/bin/python ]] || { echo 'Missing project .venv-model Python environment.' >&2; exit 1; }
export TMPDIR="$PROJECT_DIR/.tmp"
export XDG_CACHE_HOME="$PROJECT_DIR/.cache/local-vision"
export HF_HOME="$PROJECT_DIR/.cache/local-vision/huggingface"
export TORCH_HOME="$PROJECT_DIR/.cache/local-vision/torch"
export MPLCONFIGDIR="$PROJECT_DIR/.cache/local-vision/matplotlib"
export PYTORCH_ENABLE_MPS_FALLBACK=1
export PYTHONDONTWRITEBYTECODE=1
nohup "$PROJECT_DIR/.venv-model/bin/python" -u "$PROJECT_DIR/local_vision/server.py" --port "$PORT" >"$LOG_FILE" 2>&1 </dev/null &
PID=$!
echo "$PID" > "$PID_FILE"
echo "Starting PID $PID. Models can take time to load."
echo "URL: http://127.0.0.1:$PORT/"
echo "Log: $LOG_FILE"

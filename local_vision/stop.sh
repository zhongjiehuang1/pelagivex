#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${PELAGIVEX_LOCAL_PORT:-8768}"
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo 'Invalid port' >&2; exit 1; }
PID_FILE=".tmp/local-vision-$PORT.pid"
if [[ ! -f "$PID_FILE" ]]; then echo 'No local vision PID file.'; exit 0; fi
PID="$(cat "$PID_FILE")"
if [[ "$PID" =~ ^[0-9]+$ ]] && kill -0 "$PID" 2>/dev/null; then
  COMMAND="$(ps -p "$PID" -o command= || true)"
  if [[ "$COMMAND" == *"local_vision/server.py --port $PORT"* ]]; then
    kill "$PID"; echo "Stopped local vision process $PID."
  else
    echo 'PID belongs to a different process; not stopping it.' >&2; exit 1
  fi
else
  echo 'Local vision process is not running.'
fi
rm -f "$PID_FILE"

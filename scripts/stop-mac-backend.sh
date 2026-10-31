#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd -P)"
PID_FILE="$PROJECT_DIR/.tmp/mac-backend.pid"
if [ ! -f "$PID_FILE" ]; then
  echo "No recorded backend process."
  exit 0
fi
PID="$(cat "$PID_FILE")"
if [[ ! "$PID" =~ ^[0-9]+$ ]]; then
  echo "Invalid PID file; refusing to stop anything." >&2
  exit 1
fi
CMD="$(ps -p "$PID" -o command= 2>/dev/null || true)"
if [ -z "$CMD" ]; then
  rm "$PID_FILE"
  echo "Backend was already stopped."
  exit 0
fi
if [[ "$CMD" != *"com.pelagivex.LocalServer"* || "$CMD" != *"-Dpelagivex.model.path=$PROJECT_DIR/model/gate-v2.onnx"* ]]; then
  echo "PID does not match this backend; refusing to stop it." >&2
  exit 1
fi
kill "$PID"
rm "$PID_FILE"
echo "Stopped Pelagivex backend PID $PID."

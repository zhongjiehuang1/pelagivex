#!/bin/bash
# Foreground Mac model + private WSS + SSH reverse tunnel. Ctrl-C stops this run.
set -euo pipefail
PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$PROJECT_DIR"
umask 077
BACKEND_PORT="${PELAGIVEX_PORT:-18740}"
WSS_PORT="${PELAGIVEX_WSS_PORT:-18741}"
INFERENCE_SLOTS="${PELAGIVEX_INFERENCE_SLOTS:-4}"
WORKERS="${PELAGIVEX_STREAM_WORKERS:-$INFERENCE_SLOTS}"
[[ "$INFERENCE_SLOTS" =~ ^[1-4]$ && "$WORKERS" =~ ^[1-4]$ && "$WORKERS" -le "$INFERENCE_SLOTS" ]] || { echo "推理槽和帧流工作数必须为 1–4，且工作数不能超过推理槽。" >&2; exit 1; }
REMOTE_PORT="${PELAGIVEX_REMOTE_PORT:-18907}"
INSTANCE="wss-$${RANDOM}"
PY="$PROJECT_DIR/.venv-model/bin/python"
TARGET='root@8.211.120.109'
SSH=/usr/bin/ssh
TEST_MODE="${PELAGIVEX_TEST_MODE:-0}"
if [ "$TEST_MODE" = 1 ]; then SSH="$PROJECT_DIR/.tmp/ws-prototype/fake-ssh"; fi
for port in "$BACKEND_PORT" "$WSS_PORT" "$REMOTE_PORT"; do
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1024 && port <= 65535 )) || { echo 'Invalid port.' >&2; exit 1; }
done
[ "$BACKEND_PORT" != "$WSS_PORT" ] || { echo 'Backend and WSS ports must differ.' >&2; exit 1; }
[ -x "$PY" ] || { echo '项目 Python 虚拟环境不存在。' >&2; exit 1; }
"$PY" -c 'import websockets' || { echo '缺少依赖，请在项目虚拟环境安装 scripts/requirements-wss.txt。' >&2; exit 1; }
"$PY" - "$BACKEND_PORT" "$WSS_PORT" <<'PY'
import socket,sys
held=[]
try:
 for value in sys.argv[1:]:
  s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('127.0.0.1',int(value))); held.append(s)
except OSError:
 print('本机端口已被占用，请先停止已有实例。',file=sys.stderr);sys.exit(1)
finally:
 for s in held:s.close()
PY
mkdir -p "$PROJECT_DIR/.tmp"
RUN_DIR="$(mktemp -d "$PROJECT_DIR/.tmp/wss-run.XXXXXXXX")"
CONTROL="$RUN_DIR/ssh.sock"
BACKEND_PID=''; WSS_PID=''; CAFFEINATE_PID=''
stop_child() {
  local pid="$1" marker="$2" cmd
  [ -n "$pid" ] || return 0
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$cmd" == *"$marker"* ]] || return 0
  kill -TERM "$pid" 2>/dev/null || true
}
cleanup() {
  trap - EXIT INT TERM HUP
  if [ -e "$CONTROL" ]; then "$SSH" -S "$CONTROL" -O exit "$TARGET" >/dev/null 2>&1 || true; fi
  stop_child "$WSS_PID" 'scripts/wss_site.py'
  if [ "$TEST_MODE" = 1 ]; then stop_child "$BACKEND_PID" 'fake_health_backend.py'; else stop_child "$BACKEND_PID" "com.pelagivex.LocalServer $BACKEND_PORT"; fi
  stop_child "$CAFFEINATE_PID" 'caffeinate'
  wait 2>/dev/null || true
  rm -f -- "$RUN_DIR/token" "$CONTROL" "$PROJECT_DIR/.tmp/$INSTANCE.pid"
  echo '本次公网入口与识别服务已停止。'
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
"$PY" - "$RUN_DIR/token" <<'PY'
from pathlib import Path
import secrets,sys
p=Path(sys.argv[1]);p.write_text(secrets.token_urlsafe(24));p.chmod(0o600)
PY
export PELAGIVEX_PORT="$BACKEND_PORT" PELAGIVEX_INSTANCE="$INSTANCE" PELAGIVEX_INFERENCE_SLOTS="$INFERENCE_SLOTS" TMPDIR="$PROJECT_DIR/.tmp"
echo '正在启动 Mac 识别模型…'
if [ "$TEST_MODE" = 1 ]; then
  "$PY" "$PROJECT_DIR/.tmp/ws-prototype/fake_health_backend.py" "$BACKEND_PORT" >"$RUN_DIR/backend-launch.log" 2>&1 & BACKEND_PID=$!
else
  bash scripts/start-mac-backend.sh >"$RUN_DIR/backend-launch.log" 2>&1 & BACKEND_PID=$!
fi
ready=0
for ((n=0;n<180;n++)); do
  if curl -fsS --max-time 2 "http://127.0.0.1:$BACKEND_PORT/api/health" >/dev/null 2>&1; then ready=1;break;fi
  kill -0 "$BACKEND_PID" 2>/dev/null || { echo "后端启动失败，日志：$RUN_DIR/backend-launch.log" >&2;exit 1; }
  sleep 1
done
[ "$ready" = 1 ] || { echo '模型启动超时。' >&2;exit 1; }
"$PY" scripts/wss_site.py --workers "$WORKERS" --port "$WSS_PORT" --backend-port "$BACKEND_PORT" --token-file "$RUN_DIR/token" >"$RUN_DIR/wss.log" 2>&1 & WSS_PID=$!
TOKEN="$(cat "$RUN_DIR/token")"
ready=0
for ((n=0;n<30;n++)); do
  if curl -fsS --max-time 2 "http://127.0.0.1:$WSS_PORT/$TOKEN/" >/dev/null 2>&1; then ready=1;break;fi
  kill -0 "$WSS_PID" 2>/dev/null || { echo "帧流服务启动失败，日志：$RUN_DIR/wss.log" >&2;exit 1; }
  sleep 1
done
[ "$ready" = 1 ] || { echo '帧流服务启动超时。' >&2;exit 1; }
echo '正在连接你的服务器；如终端提示，请输入服务器密码（输入时不会显示，脚本不会保存）。'
"$SSH" -f -N -M -S "$CONTROL" -o StrictHostKeyChecking=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=20 -o ServerAliveCountMax=3 -R "127.0.0.1:$REMOTE_PORT:127.0.0.1:$WSS_PORT" "$TARGET" || { echo '服务器连接失败或远端端口已占用。' >&2;exit 1; }
"$SSH" -S "$CONTROL" -O check "$TARGET" >/dev/null 2>&1 || { echo '隧道未能保持连接。' >&2;exit 1; }
if [ "$TEST_MODE" = 1 ]; then
  URL="http://127.0.0.1:$WSS_PORT/$TOKEN/"
else
  URL="https://pelagivex.zhongjiehuang.com/mac-ws/$TOKEN/"
fi
if [ "$TEST_MODE" = 1 ]; then
  "$PY" scripts/check_wss_network.py --token-file "$RUN_DIR/token" --local-port "$WSS_PORT" || exit 1
else
  "$PY" scripts/check_wss_network.py --token-file "$RUN_DIR/token" || exit 1
fi
/usr/bin/caffeinate -i -s -w "$$" & CAFFEINATE_PID=$!
printf '\n手机访问（链接相当于密码，请勿公开）：\n%s\n\n保持 Mac 开机联网；按 Ctrl-C 停止本次服务。\n' "${URL}?capture=120"
while kill -0 "$BACKEND_PID" 2>/dev/null && kill -0 "$WSS_PID" 2>/dev/null && "$SSH" -S "$CONTROL" -O check "$TARGET" >/dev/null 2>&1; do sleep 3; done
echo "服务或隧道已退出，正在停止本次运行。日志：$RUN_DIR" >&2
exit 1

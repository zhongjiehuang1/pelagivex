#!/bin/bash
# Run the LAN demonstration in this terminal; no passwords are saved.
set -euo pipefail
PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$PROJECT_DIR"
BACKEND_PORT="${PELAGIVEX_PORT:-18707}"
RTC_PORT="${PELAGIVEX_RTC_HTTP_PORT:-18713}"
REMOTE_PORT="${PELAGIVEX_REMOTE_PORT:-18906}"
for port in "$BACKEND_PORT" "$RTC_PORT" "$REMOTE_PORT"; do
  [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1024 && port <= 65535)) || { echo '端口配置无效。' >&2; exit 1; }
done
[ "$BACKEND_PORT" != "$RTC_PORT" ] || { echo '本机端口不能相同。' >&2; exit 1; }
[ -t 0 ] || { echo '请在 Mac 的终端中运行此脚本，以便交互输入 SSH 密码。' >&2; exit 1; }
[ -x .venv-webrtc/bin/python ] && [ -r scripts/start-mac-backend.sh ] || { echo '项目的 WebRTC 环境或后端脚本不存在。' >&2; exit 1; }
.venv-webrtc/bin/python -c 'import aiortc,aiohttp' >/dev/null 2>&1 || { echo 'WebRTC 依赖未安装，请参阅 README。' >&2; exit 1; }
for port in "$BACKEND_PORT" "$RTC_PORT"; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "本机端口 $port 已被占用；现有服务不会被更改。" >&2; exit 1
  fi
done
BIND_IP="${PELAGIVEX_RTC_BIND_IP:-$(ipconfig getifaddr en0 || true)}"
[ -n "$BIND_IP" ] || { echo '没有找到 Wi-Fi IPv4 地址；请连接 Wi-Fi。' >&2; exit 1; }
umask 077
mkdir -p "$PROJECT_DIR/.tmp"
RUN_DIR="$(mktemp -d "$PROJECT_DIR/.tmp/lan-demo.XXXXXXXX")"
INSTANCE="lan-demo-$$"
BACKEND_PID=''; RTC_PID=''; SSH_PID=''; CAFFEINATE_PID=''
cleanup() {
  trap - EXIT INT TERM
  for pid in "$SSH_PID" "$RTC_PID" "$BACKEND_PID" "$CAFFEINATE_PID"; do
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "$SSH_PID" "$RTC_PID" "$BACKEND_PID" "$CAFFEINATE_PID"; do
    [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  done
  rm -f -- "$RUN_DIR/token" "$PROJECT_DIR/.tmp/$INSTANCE.pid"
  echo '已停止本次局域网演示。'
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
.venv-webrtc/bin/python - "$RUN_DIR/token" <<'PY'
import secrets,sys
from pathlib import Path
Path(sys.argv[1]).write_text(secrets.token_urlsafe(24))
PY
TOKEN="$(cat "$RUN_DIR/token")"
export PELAGIVEX_PORT="$BACKEND_PORT" PELAGIVEX_INSTANCE="$INSTANCE"
echo '正在启动本机模型，首次加载可能需要一些时间…'
bash scripts/start-mac-backend.sh >"$RUN_DIR/backend-launch.log" 2>&1 & BACKEND_PID=$!
ready=0
for ((n=0;n<90;n++)); do
  if curl -fsS --max-time 2 "http://127.0.0.1:$BACKEND_PORT/api/health" >/dev/null 2>&1; then ready=1;break;fi
  kill -0 "$BACKEND_PID" 2>/dev/null || { echo "模型启动失败，日志：$PROJECT_DIR/.tmp/$INSTANCE.log" >&2;exit 1; }
  sleep 1
done
[ "$ready" = 1 ] || { echo '模型启动超时。' >&2;exit 1; }
export PELAGIVEX_RTC_TOKEN_FILE="$RUN_DIR/token" PELAGIVEX_RTC_BIND_IP="$BIND_IP"
export PELAGIVEX_RTC_HTTP_PORT="$RTC_PORT" PELAGIVEX_RTC_BACKEND_PORT="$BACKEND_PORT"
export PELAGIVEX_RTC_INSTANCE="$INSTANCE" PELAGIVEX_RTC_METRICS_FILE="$RUN_DIR/metrics.json"
export TMPDIR="$PROJECT_DIR/.tmp"
.venv-webrtc/bin/python scripts/lan_rtc.py >"$RUN_DIR/rtc.log" 2>&1 & RTC_PID=$!
ready=0
for ((n=0;n<45;n++)); do
  if curl -fsS --max-time 2 "http://127.0.0.1:$RTC_PORT/$TOKEN/health" >/dev/null 2>&1; then ready=1;break;fi
  kill -0 "$RTC_PID" 2>/dev/null || { echo "局域网服务启动失败，日志：$RUN_DIR/rtc.log" >&2;exit 1; }
  sleep 1
done
[ "$ready" = 1 ] || { echo '局域网服务启动超时。' >&2;exit 1; }
# The existing per-project HTTPS route on the user's server forwards this
# loopback port. Password input is handled only by OpenSSH through the tty.
echo '请输入你自己的服务器 SSH 密码（仅用于本次连接，不会保存）：'
SSH_BIN="${PELAGIVEX_SSH_BIN:-/usr/bin/ssh}"
"$SSH_BIN" -N -o StrictHostKeyChecking=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ConnectTimeout=15 -R "127.0.0.1:$REMOTE_PORT:127.0.0.1:$RTC_PORT" root@8.211.120.109 </dev/tty & SSH_PID=$!
BASE='https://pelagivex.zhongjiehuang.com/mac-rtc'
# Optional loopback-only endpoint is for isolated lifecycle tests.
if [ -n "${PELAGIVEX_TEST_HEALTH_BASE:-}" ]; then
  case "$PELAGIVEX_TEST_HEALTH_BASE" in http://127.0.0.1:*) BASE="$PELAGIVEX_TEST_HEALTH_BASE";; *) echo '测试地址必须是本机回环。' >&2;exit 1;; esac
fi
ready=0
for ((n=0;n<90;n++)); do
  if curl -fsS --max-time 2 "$BASE/$TOKEN/health" 2>/dev/null | .venv-webrtc/bin/python -c 'import json,os,sys; sys.exit(0 if json.load(sys.stdin).get("instance")==os.environ["PELAGIVEX_RTC_INSTANCE"] else 1)' 2>/dev/null; then ready=1;break;fi
  kill -0 "$SSH_PID" 2>/dev/null || { echo 'SSH 连接失败，或服务器转发端口已被占用。' >&2;exit 1; }
  kill -0 "$RTC_PID" 2>/dev/null || { echo '局域网服务已退出。' >&2;exit 1; }
  sleep 1
done
[ "$ready" = 1 ] || { echo 'HTTPS 路由未能连接到本次实例，请检查服务器配置。' >&2;exit 1; }
caffeinate -i -s -w $$ & CAFFEINATE_PID=$!
printf '\n手机访问（完整链接相当于密码，请勿公开）：\n%s/%s/\n\n保持此终端窗口和 Mac 运行，按 Control-C 停止。\n' "$BASE" "$TOKEN"
while kill -0 "$BACKEND_PID" 2>/dev/null && kill -0 "$RTC_PID" 2>/dev/null && kill -0 "$SSH_PID" 2>/dev/null; do sleep 2;done
echo '一个服务已退出，正在停止本次演示。' >&2
exit 1

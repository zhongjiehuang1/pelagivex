#!/bin/bash
# Run an isolated Pelagivex backend and private HTTPS tunnel in this terminal.
set -euo pipefail
PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$PROJECT_DIR"
BACKEND_PORT="${PELAGIVEX_PORT:-18707}"
PROXY_PORT="${PELAGIVEX_PROXY_PORT:-18708}"
for port in "$BACKEND_PORT" "$PROXY_PORT"; do
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1024 && port <= 65535 )) || { echo 'Invalid port.' >&2; exit 1; }
done
[ "$BACKEND_PORT" != "$PROXY_PORT" ] || { echo 'Backend and proxy ports must differ.' >&2; exit 1; }
python3 - "$BACKEND_PORT" "$PROXY_PORT" <<'PY'
import socket,sys
sockets=[]
try:
    for arg in sys.argv[1:]:
        s=socket.socket(); s.bind(('127.0.0.1',int(arg))); sockets.append(s)
except OSError:
    print('A required local port is already in use; stop the existing instance or set PELAGIVEX_PORT and PELAGIVEX_PROXY_PORT.',file=sys.stderr)
    sys.exit(1)
finally:
    for s in sockets: s.close()
PY
umask 077
mkdir -p "$PROJECT_DIR/.tmp"
RUN_DIR="$(mktemp -d "$PROJECT_DIR/.tmp/mobile-demo.XXXXXXXX")"
INSTANCE="mobile-$$"
BACKEND_PID=''; PROXY_PID=''; TUNNEL_PID=''
stop_child() {
  local child="$1" marker="$2" cmd
  [ -n "$child" ] || return 0
  cmd="$(ps -p "$child" -o command= 2>/dev/null || true)"
  [[ "$cmd" == *"$marker"* ]] || return 0
  kill -TERM "$child" 2>/dev/null || true
}
cleanup() {
  trap - EXIT INT TERM
  stop_child "$TUNNEL_PID" "$RUN_DIR/cloudflared.yml"
  stop_child "$PROXY_PID" "$RUN_DIR/token"
  stop_child "$BACKEND_PID" "com.pelagivex.LocalServer $BACKEND_PORT"
  wait 2>/dev/null || true
  for file in "$RUN_DIR/token" "$PROJECT_DIR/.tmp/$INSTANCE.pid"; do
    if [ -f "$file" ]; then rm -- "$file"; fi
  done
  echo '临时公网入口和本次启动的服务已停止。'
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
python3 - "$RUN_DIR/token" <<'PY'
import secrets,sys
from pathlib import Path
Path(sys.argv[1]).write_text(secrets.token_urlsafe(24))
PY
printf '{}\n' > "$RUN_DIR/cloudflared.yml"
export PELAGIVEX_PORT="$BACKEND_PORT" PELAGIVEX_INSTANCE="$INSTANCE"
echo '正在启动本机识别模型，首次加载可能需要一些时间…'
bash scripts/start-mac-backend.sh >"$RUN_DIR/backend-launch.log" 2>&1 & BACKEND_PID=$!
ready=0
for ((n=0; n<180; n++)); do
  if curl -fsS --max-time 2 "http://127.0.0.1:$BACKEND_PORT/api/health" >/dev/null 2>&1; then ready=1; break; fi
  if ! kill -0 "$BACKEND_PID" 2>/dev/null; then echo "本机后端启动失败，日志：$PROJECT_DIR/.tmp/$INSTANCE.log" >&2; exit 1; fi
  sleep 1
done
[ "$ready" = 1 ] || { echo '本机模型启动超时。' >&2; exit 1; }
python3 scripts/secure_tunnel_proxy.py --listen-port "$PROXY_PORT" --backend-port "$BACKEND_PORT" --token-file "$RUN_DIR/token" --metrics-file "$RUN_DIR/metrics.json" >"$RUN_DIR/proxy.log" 2>&1 & PROXY_PID=$!
.cache/cloudflared/cloudflared tunnel --config "$RUN_DIR/cloudflared.yml" --no-autoupdate --metrics 127.0.0.1:0 --url "http://127.0.0.1:$PROXY_PORT" >"$RUN_DIR/tunnel.log" 2>&1 & TUNNEL_PID=$!
BASE=''
for ((n=0; n<60; n++)); do
  BASE="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$RUN_DIR/tunnel.log" | head -n 1 || true)"
  [ -n "$BASE" ] && break
  if ! kill -0 "$TUNNEL_PID" 2>/dev/null || ! kill -0 "$PROXY_PID" 2>/dev/null; then echo "公网入口启动失败，日志：$RUN_DIR" >&2; exit 1; fi
  sleep 1
done
[ -n "$BASE" ] || { echo "公网入口启动超时，日志：$RUN_DIR" >&2; exit 1; }
TOKEN="$(cat "$RUN_DIR/token")"
ready=0
DNS_DELAYED=0
HOSTNAME_PART="${BASE#https://}"
for ((n=0; n<60; n++)); do
  if curl -fsS --max-time 4 "$BASE/$TOKEN/api/health" >/dev/null 2>&1; then ready=1; break; fi
  # Some local resolvers cache an initial NXDOMAIN for a new temporary tunnel.
  # Query a public resolver and preserve TLS hostname verification for the check.
  ADDRESS="$(dig @1.1.1.1 +time=2 +tries=1 +short "$HOSTNAME_PART" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)"
  if [ -n "$ADDRESS" ] && curl -fsS --max-time 4 --resolve "$HOSTNAME_PART:443:$ADDRESS" "$BASE/$TOKEN/api/health" >/dev/null 2>&1; then ready=1; DNS_DELAYED=1; break; fi
  if ! kill -0 "$TUNNEL_PID" 2>/dev/null || ! kill -0 "$PROXY_PID" 2>/dev/null || ! kill -0 "$BACKEND_PID" 2>/dev/null; then echo "连接中断，日志：$RUN_DIR" >&2; exit 1; fi
  sleep 1
done
[ "$ready" = 1 ] || { echo "公网入口验证超时，日志：$RUN_DIR" >&2; exit 1; }
[ "$DNS_DELAYED" = 0 ] || echo '新域名已在公网注册；本机 DNS 若暂未更新，手机可能需要稍等再访问。'
printf '\n手机访问（此链接相当于密码，请勿公开）：\n%s/%s/\n\n保持 Mac 唤醒并连接网络。按 Ctrl-C 停止本次服务。\n' "$BASE" "$TOKEN"
while kill -0 "$BACKEND_PID" 2>/dev/null && kill -0 "$PROXY_PID" 2>/dev/null && kill -0 "$TUNNEL_PID" 2>/dev/null; do sleep 2; done
echo "某个服务已退出，正在停止本次服务。日志：$RUN_DIR" >&2
exit 1

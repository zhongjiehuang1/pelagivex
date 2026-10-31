#!/bin/bash
# Stop only the precisely identified temporary WSS staging instance.
set -euo pipefail
PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$PROJECT_DIR"
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != '--check' ]; }; then
  echo '用法：stop_wss_staging.sh [--check]' >&2; exit 1
fi
CURRENT_UID="$(id -u)"
read_pid() {
  local path="$1" value
  [ -r "$path" ] || { echo "缺少 PID 文件：$path；为安全起见未停止任何进程。" >&2; return 1; }
  IFS= read -r value < "$path" || return 1
  [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 1 ] || { echo "PID 文件无效：$path" >&2; return 1; }
  printf '%s' "$value"
}
check_proc() {
  local pid="$1" marker="$2" label="$3" line owner
  line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [ -n "$line" ] || return 2
  owner="$(ps -p "$pid" -o uid= 2>/dev/null | tr -d ' ')"
  [[ "$owner" = "$CURRENT_UID" && "$line" == *"$marker"* ]] || { echo "$label 的 PID 与预期进程不匹配；未继续。" >&2; return 1; }
  return 0
}
check_listener() {
  local pid="$1" port="$2" label="$3" actual
  actual="$(lsof -nP -a -p "$pid" -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true)"
  [ "$actual" = "$pid" ] || { echo "$label 未独占预期监听端口 $port；未继续。" >&2; return 1; }
}
pid_count=0
for path in .tmp/wss-staging-server.pid .tmp/wss-staging-tunnel.pid .tmp/rtc-active.pid; do
  [ ! -e "$path" ] || pid_count=$((pid_count + 1))
done
if [ "$pid_count" -eq 0 ]; then
  if [ -n "$(lsof -nP -t -iTCP:18716 -sTCP:LISTEN 2>/dev/null || true)" ] || [ -n "$(lsof -nP -t -iTCP:18707 -sTCP:LISTEN 2>/dev/null || true)" ]; then
    echo '无 PID 文件，但相关端口仍被占用；未修改任何进程。' >&2; exit 1
  fi
  if ps -Ao command= | awk 'index($0,"ssh ")==1 && index($0,"-R 127.0.0.1:18907:127.0.0.1:18716 root@8.211.120.109")>0 {found=1} END {exit !found}'; then
    echo '无 PID 文件，但相同隧道仍在运行；未修改任何进程。' >&2; exit 1
  fi
  echo '此前的 WSS 测试实例已停止。'; exit 0
fi
[ "$pid_count" -eq 3 ] || { echo 'PID 文件不完整；为安全起见未停止任何进程。' >&2; exit 1; }
WS_PID="$(read_pid .tmp/wss-staging-server.pid)"
SSH_PID="$(read_pid .tmp/wss-staging-tunnel.pid)"
JAVA_PID="$(read_pid .tmp/rtc-active.pid)"
# A previous Codex session may already have ended all three processes. Do not
# let stale PID files prevent the user from starting a new instance.
if ! kill -0 "$WS_PID" 2>/dev/null && ! kill -0 "$SSH_PID" 2>/dev/null && ! kill -0 "$JAVA_PID" 2>/dev/null; then
  if [ -n "$(lsof -nP -t -iTCP:18716 -sTCP:LISTEN 2>/dev/null || true)" ] || [ -n "$(lsof -nP -t -iTCP:18707 -sTCP:LISTEN 2>/dev/null || true)" ]; then
    echo '记录的进程已退出，但相关端口被其他服务占用；未修改任何进程。' >&2; exit 1
  fi
  if [ "${1:-}" != '--check' ]; then rm -f -- .tmp/wss-staging-server.pid .tmp/wss-staging-tunnel.pid .tmp/rtc-active.pid; fi
  echo '此前的 WSS 测试实例已停止。'; exit 0
fi
# All-or-nothing preflight: never act on stale or reused PIDs.
check_proc "$WS_PID" '.tmp/ws-prototype/mobile-staging.py' '帧流服务' || { echo '帧流服务未处于预期状态；请手动检查。' >&2; exit 1; }
check_proc "$SSH_PID" '-R 127.0.0.1:18907:127.0.0.1:18716 root@8.211.120.109' 'SSH 隧道' || { echo 'SSH 隧道未处于预期状态；请手动检查。' >&2; exit 1; }
check_proc "$JAVA_PID" "com.pelagivex.LocalServer 18707" '本机识别服务' || { echo '识别服务未处于预期状态；请手动检查。' >&2; exit 1; }
JAVA_CMD="$(ps -p "$JAVA_PID" -o command=)"
[[ "$JAVA_CMD" == *"-Dpelagivex.model.path=$PROJECT_DIR/model/gate-v2.onnx"* ]] || { echo '模型路径不匹配；未继续。' >&2; exit 1; }
check_listener "$WS_PID" 18716 '帧流服务'
check_listener "$JAVA_PID" 18707 '本机识别服务'
other_clients() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [[ "$p" = "$JAVA_PID" || "$p" = "$WS_PID" ]] || { printf '%s\n' "$p"; return 0; }
  done < <(lsof -nP -t -iTCP:18707 2>/dev/null | sort -u || true)
}
[ -z "$(other_clients)" ] || { echo '检测到其他进程正在使用识别服务；未停止任何进程。' >&2; exit 1; }
if [ "${1:-}" = '--check' ]; then echo '目标进程、端口和客户端检查通过；未停止任何服务。'; exit 0; fi
[ "$#" -eq 0 ] || { echo '用法：stop_wss_staging.sh [--check]' >&2; exit 1; }
# After preflight, recheck each command immediately before signalling.
check_proc "$SSH_PID" '-R 127.0.0.1:18907:127.0.0.1:18716 root@8.211.120.109' 'SSH 隧道'; kill -TERM "$SSH_PID"
check_proc "$WS_PID" '.tmp/ws-prototype/mobile-staging.py' '帧流服务'; kill -TERM "$WS_PID"
[ -z "$(other_clients)" ] || { echo '发现其他进程正在使用识别服务，已保留该服务。' >&2; exit 1; }
check_proc "$JAVA_PID" 'com.pelagivex.LocalServer 18707' '本机识别服务'; kill -TERM "$JAVA_PID"
for _ in 1 2 3 4 5; do
  if ! kill -0 "$WS_PID" 2>/dev/null && ! kill -0 "$SSH_PID" 2>/dev/null && ! kill -0 "$JAVA_PID" 2>/dev/null; then break; fi
  sleep 1
done
for pid in "$WS_PID" "$SSH_PID" "$JAVA_PID"; do
  if kill -0 "$pid" 2>/dev/null; then echo "进程 $pid 尚未退出，请检查；不会强制结束。" >&2; exit 1; fi
done
rm -f -- .tmp/wss-staging-server.pid .tmp/wss-staging-tunnel.pid .tmp/rtc-active.pid
echo '本次旧 WSS 测试实例及其专用隧道已停止。'

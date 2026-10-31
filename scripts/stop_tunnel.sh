#!/bin/sh
# Stop only the two processes belonging to this temporary Pelagivex tunnel.
set -u
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P) || exit 1
stop_verified() {
    pid_file="$1"
    expected="$2"
    if [ ! -r "$pid_file" ]; then
        printf 'No recorded %s process.\n' "$3"
        return 0
    fi
    IFS= read -r pid < "$pid_file" || return 1
    case "$pid" in ''|*[!0-9]*) printf 'Invalid PID in %s\n' "$pid_file" >&2; return 1;; esac
    command_line=$(ps -p "$pid" -o command= 2>/dev/null || true)
    if [ -z "$command_line" ]; then
        printf '%s is already stopped.\n' "$3"
        return 0
    fi
    case "$command_line" in
        *"$expected"*) kill -TERM "$pid" && printf '%s stopped.\n' "$3";;
        *) printf 'PID %s does not match %s; left running.\n' "$pid" "$3" >&2; return 1;;
    esac
}
stop_verified "$project_dir/.tmp/public-tunnel.pid" 'cloudflared tunnel --config .tmp/cloudflared-empty.yml --no-autoupdate --metrics 127.0.0.1:0 --url http://127.0.0.1:18695' 'Public tunnel' || exit 1
stop_verified "$project_dir/.tmp/private-proxy.pid" 'scripts/secure_tunnel_proxy.py --listen-port 18695 --backend-port 8767 --token-file .tmp/private-tunnel-token' 'Access proxy'

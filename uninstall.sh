#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ $(uname -s) == "Darwin" ]]; then
    exec "$project_root/macos/uninstall.sh" "$@"
fi

purge_logs=false
if [[ ${1:-} == "--purge-logs" ]]; then
    purge_logs=true
    shift
fi
if [[ $# -ne 0 ]]; then
    echo "Usage: ./uninstall.sh [--purge-logs]" >&2
    exit 2
fi

data_home=${XDG_DATA_HOME:-"$HOME/.local/share"}
config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
cache_home=${XDG_CACHE_HOME:-"$HOME/.cache"}
state_home=${XDG_STATE_HOME:-"$HOME/.local/state"}
installed_path="$HOME/.local/bin/claude-usage-tray"
application_path="$data_home/applications/claude-usage-tray.desktop"
autostart_path="$config_home/autostart/claude-usage-tray.desktop"
cache_root="$cache_home/claude-usage-tray"
pid_path="$cache_root/claude-usage-tray.pid"
log_root="$state_home/claude-usage-tray"

if [[ -f "$pid_path" ]]; then
    process_id=$(head -n 1 -- "$pid_path" 2>/dev/null || true)
    if [[ $process_id =~ ^[0-9]+$ && -r "/proc/$process_id/cmdline" ]] &&
        tr '\0' '\n' < "/proc/$process_id/cmdline" | grep -Fqx -- "$installed_path"; then
        kill -TERM "$process_id"
        for _attempt in {1..50}; do
            kill -0 "$process_id" 2>/dev/null || break
            sleep 0.1
        done
    fi
fi

rm -f -- "$installed_path" "$application_path" "$autostart_path"
rm -rf -- "$cache_root"

if $purge_logs; then
    rm -rf -- "$log_root"
fi

rmdir -- "$HOME/.local/bin" 2>/dev/null || true
rmdir -- "$(dirname -- "$application_path")" 2>/dev/null || true
rmdir -- "$(dirname -- "$autostart_path")" 2>/dev/null || true

echo "Claude Usage Tray was uninstalled."
if ! $purge_logs; then
    echo "Logs were preserved at $log_root"
fi

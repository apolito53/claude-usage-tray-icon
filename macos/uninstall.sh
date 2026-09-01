#!/usr/bin/env bash
set -euo pipefail

purge_logs=false
if [[ ${1:-} == "--purge-logs" ]]; then
    purge_logs=true
    shift
fi
if [[ $# -ne 0 ]]; then
    echo "Usage: ./uninstall.sh [--purge-logs]" >&2
    exit 2
fi
if [[ $(uname -s) != "Darwin" ]]; then
    echo "The macOS uninstaller must run on macOS." >&2
    exit 1
fi

application_root="$HOME/Library/Application Support/ClaudeUsageTray"
installed_path="$application_root/ClaudeUsageTray"
launch_agent_path="$HOME/Library/LaunchAgents/com.apolito.claude-usage-tray.plist"
cache_root="$HOME/Library/Caches/ClaudeUsageTray"
pid_path="$cache_root/claude-usage-tray.pid"
log_root="$HOME/Library/Logs/ClaudeUsageTray"
service_target="gui/$(id -u)/com.apolito.claude-usage-tray"

launchctl bootout "$service_target" >/dev/null 2>&1 || true
if [[ -f "$pid_path" ]]; then
    process_id=$(head -n 1 -- "$pid_path" 2>/dev/null || true)
    if [[ $process_id =~ ^[0-9]+$ ]]; then
        process_command=$(ps -p "$process_id" -o command= 2>/dev/null || true)
        if [[ $process_command == "$installed_path" ]]; then
            kill -TERM "$process_id"
            for _attempt in {1..50}; do
                kill -0 "$process_id" 2>/dev/null || break
                sleep 0.1
            done
        fi
    fi
fi

rm -f -- "$installed_path" "$launch_agent_path"
rm -rf -- "$cache_root"
rmdir -- "$application_root" 2>/dev/null || true

if $purge_logs; then
    rm -rf -- "$log_root"
fi

echo "Claude Usage Tray was uninstalled."
if ! $purge_logs; then
    echo "Logs were preserved at $log_root"
fi

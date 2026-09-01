#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: ./install.sh [--no-startup]"
}

start_at_login=true
if [[ ${1:-} == "--no-startup" ]]; then
    start_at_login=false
    shift
fi
if [[ $# -ne 0 ]]; then
    usage >&2
    exit 2
fi
if [[ $(uname -s) != "Darwin" ]]; then
    echo "The macOS installer must run on macOS." >&2
    exit 1
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
application_root="$HOME/Library/Application Support/ClaudeUsageTray"
installed_path="$application_root/ClaudeUsageTray"
launch_agent_root="$HOME/Library/LaunchAgents"
launch_agent_path="$launch_agent_root/com.apolito.claude-usage-tray.plist"
cache_root="$HOME/Library/Caches/ClaudeUsageTray"
pid_path="$cache_root/claude-usage-tray.pid"
log_root="$HOME/Library/Logs/ClaudeUsageTray"
service_target="gui/$(id -u)/com.apolito.claude-usage-tray"
build_root=$(mktemp -d "${TMPDIR:-/tmp}/claude-usage-tray.XXXXXX")
trap 'rm -rf -- "$build_root"' EXIT

"$project_root/macos/build.sh" "$build_root/ClaudeUsageTray"
"$build_root/ClaudeUsageTray" \
    --mock-response "$project_root/tests/fixtures/usage_response.json" \
    >/dev/null

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

install -d -- "$application_root" "$launch_agent_root" "$cache_root" "$log_root"
chmod 0700 "$cache_root" "$log_root"
install -m 0755 -- "$build_root/ClaudeUsageTray" "$installed_path"

xml_path=$(printf '%s' "$installed_path" | /usr/bin/sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\\&apos;/g")

write_launch_agent() {
    temporary_path="$launch_agent_path.tmp"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        echo '<plist version="1.0">'
        echo '<dict>'
        echo '  <key>Label</key>'
        echo '  <string>com.apolito.claude-usage-tray</string>'
        echo '  <key>ProgramArguments</key>'
        echo '  <array>'
        echo "    <string>$xml_path</string>"
        echo '  </array>'
        echo '  <key>RunAtLoad</key>'
        echo '  <true/>'
        echo '  <key>ProcessType</key>'
        echo '  <string>Interactive</string>'
        echo '  <key>LimitLoadToSessionType</key>'
        echo '  <string>Aqua</string>'
        echo '</dict>'
        echo '</plist>'
    } > "$temporary_path"
    plutil -lint "$temporary_path" >/dev/null
    chmod 0644 "$temporary_path"
    mv -f -- "$temporary_path" "$launch_agent_path"
}

if $start_at_login; then
    write_launch_agent
    launchctl bootstrap "gui/$(id -u)" "$launch_agent_path"
else
    rm -f -- "$launch_agent_path"
    nohup "$installed_path" >/dev/null 2>&1 &
fi

echo "Installed and launched $installed_path"
if $start_at_login; then
    echo "Start at login: on"
else
    echo "Start at login: off"
fi

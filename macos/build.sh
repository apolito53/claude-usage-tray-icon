#!/usr/bin/env bash
set -euo pipefail

if [[ $(uname -s) != "Darwin" ]]; then
    echo "macos/build.sh must run on macOS." >&2
    exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Swift is missing. Install Apple's Command Line Tools with: xcode-select --install" >&2
    exit 1
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_path=${1:-"$project_root/build/ClaudeUsageTray"}
install -d -- "$(dirname -- "$output_path")"

xcrun swiftc \
    -swift-version 5 \
    -O \
    -framework AppKit \
    -framework Security \
    "$project_root/macos/ClaudeUsageTray.swift" \
    -o "$output_path"

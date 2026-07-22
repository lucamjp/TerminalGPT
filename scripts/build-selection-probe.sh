#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_PATH="/private/tmp/ChatGPT Selection Probe"
MODULE_CACHE="$ROOT_DIR/build/selection-probe-module-cache"
mkdir -p "$MODULE_CACHE"

/usr/bin/swiftc \
    -module-cache-path "$MODULE_CACHE" \
    "$ROOT_DIR/Tests/SelectionProbe/main.swift" \
    -framework AppKit \
    -o "$OUTPUT_PATH"

echo "$OUTPUT_PATH"

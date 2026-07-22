#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_CACHE="$ROOT_DIR/build/typecheck-module-cache"
mkdir -p "$MODULE_CACHE"

/usr/bin/swiftc \
    -parse-as-library \
    -typecheck \
    -module-cache-path "$MODULE_CACHE" \
    "$ROOT_DIR/main.swift" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework Carbon \
    -framework PDFKit \
    -framework UniformTypeIdentifiers \
    -framework WebKit

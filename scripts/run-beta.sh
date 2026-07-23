#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/build/beta-debug/ChatGPT Terminal Beta.app"

if [[ ! -d "$APP_PATH" ]]; then
    "$ROOT_DIR/scripts/build.sh" debug beta
fi

# Starts only the development beta. It does not stop or replace the installed app.
/usr/bin/open -n "$APP_PATH"

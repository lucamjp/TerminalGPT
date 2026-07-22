#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-debug}"
VARIANT="${2:-beta}"

case "$CONFIGURATION" in
    debug)
        OPTIMIZATION_FLAGS=(-Onone -g)
        ;;
    release)
        OPTIMIZATION_FLAGS=(-O)
        ;;
    *)
        echo "Unbekannte Konfiguration: $CONFIGURATION (erlaubt: debug, release)" >&2
        exit 2
        ;;
esac

case "$VARIANT" in
    main)
        APP_NAME="ChatGPT Terminal"
        INFO_PLIST="$ROOT_DIR/Info.plist"
        VARIANT_FLAGS=()
        ;;
    beta)
        APP_NAME="ChatGPT Terminal Beta"
        INFO_PLIST="$ROOT_DIR/Info.Beta.plist"
        VARIANT_FLAGS=(-D BETA_BUILD)
        ;;
    *)
        echo "Unbekannte Variante: $VARIANT (erlaubt: main, beta)" >&2
        exit 2
        ;;
esac

BUILD_DIR="$ROOT_DIR/build/$VARIANT-$CONFIGURATION"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
EXECUTABLE_PATH="$APP_DIR/Contents/MacOS/$APP_NAME"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$BUILD_DIR/module-cache"

/usr/bin/swiftc \
    -parse-as-library \
    "${OPTIMIZATION_FLAGS[@]}" \
    "${VARIANT_FLAGS[@]}" \
    -module-cache-path "$BUILD_DIR/module-cache" \
    "$ROOT_DIR/main.swift" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework Carbon \
    -framework PDFKit \
    -framework UniformTypeIdentifiers \
    -framework WebKit \
    -o "$EXECUTABLE_PATH"

cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
xattr -cr "$APP_DIR"

SIGN_MODE="${SIGN_MODE:-adhoc}"
case "$SIGN_MODE" in
    adhoc)
        /usr/bin/codesign --force --deep --sign - "$APP_DIR"
        ;;
    local)
        SIGN_IDENTITY="${SIGN_IDENTITY:-1F15E8DBAC0A533607CA5AEFF0320416EE2BFD87}"
        SIGN_KEYCHAIN="${SIGN_KEYCHAIN:-$HOME/Library/Keychains/ChatGPTTerminalLocalSigning.keychain-db}"
        /usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" "$APP_DIR"
        ;;
    none)
        ;;
    *)
        echo "Unbekannter SIGN_MODE: $SIGN_MODE (erlaubt: adhoc, local, none)" >&2
        exit 2
        ;;
esac

echo "$APP_DIR"

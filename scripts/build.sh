#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-debug}"
VARIANT="${2:-main}"

case "$CONFIGURATION" in
    debug)
        OPTIMIZATION_FLAGS=(-Onone -g)
        ;;
    release)
        OPTIMIZATION_FLAGS=(-O)
        ;;
    *)
        echo "Unknown configuration: $CONFIGURATION (use debug or release)" >&2
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
        echo "Unknown variant: $VARIANT (use main or beta)" >&2
        exit 2
        ;;
esac

BUILD_DIR="$ROOT_DIR/build/$VARIANT-$CONFIGURATION"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
EXECUTABLE_PATH="$APP_DIR/Contents/MacOS/$APP_NAME"
SOURCE_FILES=("$ROOT_DIR"/Sources/ChatGPTTerminal/*.swift)

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$BUILD_DIR/module-cache"

/usr/bin/swiftc \
    -parse-as-library \
    "${OPTIMIZATION_FLAGS[@]}" \
    "${VARIANT_FLAGS[@]}" \
    -module-cache-path "$BUILD_DIR/module-cache" \
    "${SOURCE_FILES[@]}" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework Carbon \
    -framework PDFKit \
    -framework UniformTypeIdentifiers \
    -framework WebKit \
    -o "$EXECUTABLE_PATH"

cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"

sign_app() {
    local attempt
    for attempt in 1 2 3; do
        xattr -cr "$APP_DIR"
        if "$@"; then
            return 0
        fi
    done
    return 1
}

SIGN_MODE="${SIGN_MODE:-adhoc}"
case "$SIGN_MODE" in
    adhoc)
        sign_app /usr/bin/codesign --force --deep --sign - "$APP_DIR"
        ;;
    local)
        : "${SIGN_IDENTITY:?Set SIGN_IDENTITY when SIGN_MODE=local}"
        if [[ -n "${SIGN_KEYCHAIN:-}" ]]; then
            sign_app /usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" "$APP_DIR"
        else
            sign_app /usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
        fi
        ;;
    none)
        ;;
    *)
        echo "Unknown SIGN_MODE: $SIGN_MODE (use adhoc, local, or none)" >&2
        exit 2
        ;;
esac

xattr -cr "$APP_DIR"
echo "$APP_DIR"

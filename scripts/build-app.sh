#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="release"

usage() {
    printf 'Usage: %s [--configuration debug|release]\n' "$0"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration|-c)
            if [[ $# -lt 2 ]]; then usage >&2; exit 2; fi
            CONFIGURATION="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
    printf 'Configuration must be debug or release.\n' >&2
    exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'Mac Tools requires macOS and an installed Swift toolchain.\n' >&2
    exit 1
fi

mkdir -p "$ROOT_DIR/.build/ModuleCache" "$ROOT_DIR/build"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/ModuleCache"

BUILD_OPTIONS=(
    --package-path "$ROOT_DIR"
    --scratch-path "$ROOT_DIR/.build"
    --cache-path "$ROOT_DIR/.build/cache"
    --config-path "$ROOT_DIR/.build/config"
    --security-path "$ROOT_DIR/.build/security"
    --configuration "$CONFIGURATION"
)

# The development configuration retains symbols; the distributable bundle does not.
if [[ "$CONFIGURATION" == "release" ]]; then
    BUILD_OPTIONS+=(-debug-info-format none)
fi

# Restricted build runners may not permit SwiftPM's nested manifest sandbox.
# Keep the normal SwiftPM behavior unless the caller explicitly opts out.
if [[ "${MAC_TOOLS_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
    BUILD_OPTIONS+=(--disable-sandbox)
fi

xcrun swift build "${BUILD_OPTIONS[@]}" --product MacTools
BIN_DIR="$(xcrun swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"

STAGING_DIR="$(mktemp -d "$ROOT_DIR/build/.mac-tools-package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/Mac Tools.app"
APP_PATH="$ROOT_DIR/build/Mac Tools.app"

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_DIR/MacTools" "$STAGED_APP/Contents/MacOS/MacTools"
cp "$ROOT_DIR/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
chmod 755 "$STAGED_APP/Contents/MacOS/MacTools"

xcrun swift -module-cache-path "$ROOT_DIR/.build/ModuleCache" \
    "$ROOT_DIR/scripts/make-icon.swift" "$STAGED_APP/Contents/Resources/AppIcon.icns"

/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$STAGED_APP"
/usr/bin/codesign --verify --strict "$STAGED_APP"

# Only replace the generated bundle after a complete build and signature check.
if [[ -e "$APP_PATH" ]]; then rm -rf "$APP_PATH"; fi
mv "$STAGED_APP" "$APP_PATH"
printf '\nBuilt %s\n' "$APP_PATH"

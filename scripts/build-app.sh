#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

BUILD_CONFIGURATION="${CONFIGURATION:-release}"
APP_PATH="${QUICKSHIFT_APP_PATH:-$PROJECT_DIR/dist/QuickShift.app}"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/ModuleCache"

if /usr/bin/pgrep -f "^$APP_PATH/Contents/MacOS/QuickShiftDisplay( |$)" >/dev/null 2>&1; then
    echo "QuickShift is running. Quit it from its menu before rebuilding." >&2
    exit 1
fi

swift build --disable-sandbox --cache-path "$PROJECT_DIR/.build/cache" -c "$BUILD_CONFIGURATION" "$@"
BIN_PATH="$(swift build --disable-sandbox --cache-path "$PROJECT_DIR/.build/cache" -c "$BUILD_CONFIGURATION" --show-bin-path "$@")"

# A fresh bundle (and executable inode) prevents macOS from reusing the old code-signing
# identity after a rebuild. Never overwrite an executable that Launch Services has loaded.
BUNDLE_STAGING_DIR="$(mktemp -d "$PROJECT_DIR/.build/app-bundle.XXXXXX")"
STAGED_APP_PATH="$BUNDLE_STAGING_DIR/QuickShift.app"
cleanup() {
    if [ -d "$BUNDLE_STAGING_DIR/PreviousQuickShift.app" ] && [ ! -e "$APP_PATH" ]; then
        mv "$BUNDLE_STAGING_DIR/PreviousQuickShift.app" "$APP_PATH"
    fi
    rm -rf "$BUNDLE_STAGING_DIR"
}
trap cleanup EXIT
mkdir -p "$STAGED_APP_PATH/Contents/MacOS" "$STAGED_APP_PATH/Contents/Resources"
cp "$BIN_PATH/QuickShiftDisplay" "$STAGED_APP_PATH/Contents/MacOS/QuickShiftDisplay"
cp "$PROJECT_DIR/Resources/Info.plist" "$STAGED_APP_PATH/Contents/Info.plist"

if [ ! -f "$PROJECT_DIR/Resources/AppIcon.icns" ] || [ "$PROJECT_DIR/scripts/make-icon.swift" -nt "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    swift "$PROJECT_DIR/scripts/make-icon.swift" "$PROJECT_DIR/Resources/AppIcon.icns"
fi
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$STAGED_APP_PATH/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign "${SIGNING_IDENTITY:--}" --options runtime --timestamp=none "$STAGED_APP_PATH"
/usr/bin/codesign --verify --strict "$STAGED_APP_PATH"
mkdir -p "$(dirname "$APP_PATH")"
if [ -e "$APP_PATH" ]; then mv "$APP_PATH" "$BUNDLE_STAGING_DIR/PreviousQuickShift.app"; fi
mv "$STAGED_APP_PATH" "$APP_PATH"
echo "Built: $APP_PATH"

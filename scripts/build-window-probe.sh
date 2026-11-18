#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROBE_PATH="$PROJECT_DIR/.build/QuickShiftProbe.app"
PROBE_STAGING_DIR="$(mktemp -d "$PROJECT_DIR/.build/probe-bundle.XXXXXX")"
STAGED_PROBE_PATH="$PROBE_STAGING_DIR/QuickShiftProbe.app"
trap 'rm -rf "$PROBE_STAGING_DIR"' EXIT
mkdir -p "$STAGED_PROBE_PATH/Contents/MacOS"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
swiftc -swift-version 6 -target "$(uname -m)-apple-macos13.0" \
    "$PROJECT_DIR/Tests/Fixtures/WindowProbe.swift" -o "$STAGED_PROBE_PATH/Contents/MacOS/QuickShiftProbe"
cat > "$STAGED_PROBE_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.quickshiftdisplay.probe</string>
<key>CFBundleName</key><string>QuickShiftProbe</string>
<key>CFBundleExecutable</key><string>QuickShiftProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$STAGED_PROBE_PATH"
if [ -e "$PROBE_PATH" ]; then mv "$PROBE_PATH" "$PROBE_STAGING_DIR/PreviousProbe.app"; fi
mv "$STAGED_PROBE_PATH" "$PROBE_PATH"
echo "Built: $PROBE_PATH"

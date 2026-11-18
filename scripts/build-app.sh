#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

BUILD_CONFIGURATION="${CONFIGURATION:-release}"
APP_PATH="${QUICKSHIFT_APP_PATH:-$PROJECT_DIR/dist/QuickShift.app}"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/ModuleCache"

identity="${SIGNING_IDENTITY:-}"
if [ -z "$identity" ]; then
    identity="$(git config --get quickshift.signingIdentity)" || {
        config_status=$?
        if [ "$config_status" -ne 1 ]; then exit "$config_status"; fi
    }
fi
if [ -z "$identity" ]; then identity=-; fi

# TCC can retain a grant when the two versions satisfy each other's designated
# requirements. A bundle identifier or a certificate name alone cannot establish this.
satisfies_designated_requirements() {
    local source="$1" candidate="$2" architectures arch requirement
    architectures="$(/usr/bin/lipo -archs "$source/Contents/MacOS/QuickShiftDisplay")" || return 1
    for arch in $architectures; do
        requirement="$(/usr/bin/codesign -d -r- --arch "$arch" "$source" 2>&1 |
            /usr/bin/sed -nE 's/^(# )?designated => (.+)$/\2/p')" || return 1
        [ -n "$requirement" ] || return 1
        /usr/bin/codesign --verify --strict --all-architectures "-R=$requirement" "$candidate" >/dev/null 2>&1 || return 1
    done
    [ -n "$architectures" ]
}

swift build --disable-sandbox --cache-path "$PROJECT_DIR/.build/cache" -c "$BUILD_CONFIGURATION" "$@"
BIN_PATH="$(swift build --disable-sandbox --cache-path "$PROJECT_DIR/.build/cache" -c "$BUILD_CONFIGURATION" --show-bin-path "$@")"

# Stage on the destination volume. Launch Services must see a fresh executable inode.
mkdir -p "$(dirname "$APP_PATH")"
APP_PATH="$(cd -P "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
BUNDLE_STAGING_DIR="$(mktemp -d "$(dirname "$APP_PATH")/.quickshift-build.XXXXXX")"
STAGED_APP_PATH="$BUNDLE_STAGING_DIR/QuickShift.app"
publish_lock="$APP_PATH.build-lock"
locked=false
cleanup() {
    if [ "$locked" = true ]; then /bin/rm -f "$publish_lock"; fi
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
sign_options=(--force --sign "$identity" --options runtime)
if [ "$identity" = - ]; then
    echo "Ad hoc build. A change to the signed code can require a new Accessibility grant." >&2
    sign_options+=(--timestamp=none)
elif [[ "$identity" == "Developer ID Application:"* ]]; then
    sign_options+=(--timestamp)
fi
sign_staged_app() {
    /usr/bin/codesign "$@" "$STAGED_APP_PATH" || {
        local signing_status=$?
        echo "Signing failed for identity: $identity" >&2
        return "$signing_status"
    }
}
sign_staged_app "${sign_options[@]}"
# codesign normally timestamps Developer ID automatically. Also cover identities
# selected by fingerprint and require a secure timestamp for distribution.
signature="$(/usr/bin/codesign -dvvv "$STAGED_APP_PATH" 2>&1)"
if [[ "$identity" != "Developer ID Application:"* && "$signature" == *"Authority=Developer ID Application:"* && "$signature" != *"Timestamp="* ]]; then
    sign_staged_app "${sign_options[@]}" --timestamp
fi
/usr/bin/codesign --verify --strict --all-architectures "$STAGED_APP_PATH"

if ! /usr/bin/shlock -p "$$" -f "$publish_lock"; then
    echo "Another build is publishing to $APP_PATH." >&2
    exit 1
fi
locked=true
mode=create
if [ -e "$APP_PATH" ] || [ -L "$APP_PATH" ]; then
    existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
    if [ -L "$APP_PATH" ] || [ "$existing_id" != local.quickshiftdisplay.app ]; then
        echo "Choose a destination containing QuickShift or a new app path: $APP_PATH" >&2
        exit 1
    fi
    if /usr/bin/diff -qr "$APP_PATH" "$STAGED_APP_PATH" >/dev/null; then
        echo "Already built: $APP_PATH"
        exit 0
    fi
    if [ "${QUICKSHIFT_ALLOW_IDENTITY_CHANGE:-0}" != 1 ] &&
       ! { satisfies_designated_requirements "$APP_PATH" "$STAGED_APP_PATH" &&
           satisfies_designated_requirements "$STAGED_APP_PATH" "$APP_PATH"; }; then
        echo "Update would change QuickShift's signing identity. Existing app preserved." >&2
        echo "Use QUICKSHIFT_APP_PATH for a separate build. For an intentional migration, set QUICKSHIFT_ALLOW_IDENTITY_CHANGE=1 and grant Accessibility to the new identity once." >&2
        exit 1
    fi
    process_paths="$(/bin/ps -axww -o comm=)" || {
        echo "Unable to check whether QuickShift is running. Existing app preserved." >&2
        exit 1
    }
    if /usr/bin/grep -Fxq -- "$APP_PATH/Contents/MacOS/QuickShiftDisplay" <<< "$process_paths"; then
        echo "QuickShift is running. Quit it from its menu before replacing it." >&2
        exit 1
    fi
    mode=replace
fi
# Keep a complete application at the installation path even if the build is
# interrupted. In replace mode the previous app ends up inside our staging dir.
swift -module-cache-path "$CLANG_MODULE_CACHE_PATH" - "$STAGED_APP_PATH" "$APP_PATH" "$mode" <<'SWIFT'
import Darwin
let args = CommandLine.arguments
let flag = args[3] == "replace" ? RENAME_SWAP : RENAME_EXCL
if renamex_np(args[1], args[2], UInt32(flag)) != 0 {
    perror("Could not publish QuickShift atomically")
    exit(1)
}
SWIFT
echo "Built: $APP_PATH"

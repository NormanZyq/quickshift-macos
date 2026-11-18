#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
scratch="$(mktemp -d "${TMPDIR:-/tmp}/quickshift-signing.XXXXXX")"
scratch="$(cd -P "$scratch" && pwd)"
fixture_pid=
cleanup() {
    if [ -n "$fixture_pid" ]; then kill "$fixture_pid" 2>/dev/null || true; fi
    rm -rf "$scratch"
}
trap cleanup EXIT
export SIGNING_IDENTITY=-
export QUICKSHIFT_APP_PATH="$scratch/Folder [A]/QuickShift.app"
unset QUICKSHIFT_ALLOW_IDENTITY_CHANGE
bundle="$QUICKSHIFT_APP_PATH"
log="$scratch/build.log"

build() {
    bash scripts/build-app.sh "$@" >"$log" 2>&1 || { cat "$log" >&2; return 1; }
}
expect_rejection() {
    local message="$1"
    if bash scripts/build-app.sh >"$log" 2>&1; then
        echo "Expected build to refuse: $message" >&2
        return 1
    fi
    grep -Fq "$message" "$log" || { cat "$log" >&2; return 1; }
}
hash_executable() { shasum -a 256 "$bundle/Contents/MacOS/QuickShiftDisplay"; }

build
original="$(hash_executable)"
build
grep -Fq 'Already built:' "$log"

# An empty resource directory changes the bundle comparison but leaves its valid
# designated requirement intact. Exercise both compatibility checks and replacement.
mkdir "$bundle/Contents/Resources/empty-fixture"
build
[ ! -d "$bundle/Contents/Resources/empty-fixture" ]

# Make a different, validly signed earlier version. The normal build must keep it.
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 0' "$bundle/Contents/Info.plist"
/usr/bin/codesign --force --options runtime --timestamp=none --sign - "$bundle"
previous="$(hash_executable)"
[ "$previous" != "$original" ]
expect_rejection 'Update would change'
[ "$(hash_executable)" = "$previous" ]
missing_identity="QuickShift Missing Test Certificate $$"
SIGNING_IDENTITY="$missing_identity" expect_rejection "$missing_identity"
[ "$(hash_executable)" = "$previous" ]

# The process guard must still apply during an explicit migration. Use a sleeping
# fixture at the executable path so the test never starts QuickShift or requests AX.
cp /bin/sleep "$scratch/SleepFixture"
mv "$scratch/SleepFixture" "$bundle/Contents/MacOS/QuickShiftDisplay"
/usr/bin/codesign --force --options runtime --timestamp=none --sign - "$bundle"
"$bundle/Contents/MacOS/QuickShiftDisplay" 120 &
fixture_pid=$!
export QUICKSHIFT_ALLOW_IDENTITY_CHANGE=1
expect_rejection 'QuickShift is running'
kill "$fixture_pid"
wait "$fixture_pid" 2>/dev/null || true
fixture_pid=
build
[ "$(hash_executable)" = "$original" ]
/usr/bin/codesign --verify --strict --all-architectures "$bundle"
echo "Passed signing checks for identical builds, compatible updates, incompatible updates, missing certificates, running apps, and explicit migration."

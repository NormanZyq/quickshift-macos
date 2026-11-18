#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
scratch="$(mktemp -d "${TMPDIR:-/tmp}/quickshift-signing.XXXXXX")"
scratch="$(cd -P "$scratch" && pwd)"
fixture_pid=
cleanup() {
    if [ -n "$fixture_pid" ]; then
        kill "$fixture_pid" 2>/dev/null || true
        wait "$fixture_pid" 2>/dev/null || true
    fi
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
        cat "$log" >&2
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
# Match the build's diagnostic, not codesign's version-dependent keychain wording.
SIGNING_IDENTITY="$missing_identity" expect_rejection "Signing failed for identity: $missing_identity"
[ "$(hash_executable)" = "$previous" ]

# Exercise the process guard with a runnable fixture. A copied and re-signed
# system binary can be killed by macOS before the guard has a process to detect.
cat > "$scratch/running-app.c" <<'C'
#include <stdio.h>
#include <unistd.h>

int main(void) {
    if (puts("ready") == EOF || fflush(stdout) == EOF) return 1;
    sleep(120);
    return 0;
}
C
/usr/bin/xcrun clang "$scratch/running-app.c" -o "$scratch/running-app"
executable="$bundle/Contents/MacOS/QuickShiftDisplay"
mv "$scratch/running-app" "$executable"
/usr/bin/codesign --force --options runtime --timestamp=none --sign - "$bundle"
fixture_log="$scratch/running-app.log"
: >"$fixture_log"
"$executable" >"$fixture_log" 2>&1 &
fixture_pid=$!
deadline=$((SECONDS + 5))
until grep -Fxq ready "$fixture_log"; do
    if ! kill -0 "$fixture_pid" 2>/dev/null || [ "$SECONDS" -ge "$deadline" ]; then
        echo "The signed running-app fixture did not start." >&2
        cat "$fixture_log" >&2
        exit 1
    fi
    sleep 0.1
done
export QUICKSHIFT_ALLOW_IDENTITY_CHANGE=1
expect_rejection 'QuickShift is running'
kill "$fixture_pid"
wait "$fixture_pid" 2>/dev/null || true
fixture_pid=
build
[ "$(hash_executable)" = "$original" ]
/usr/bin/codesign --verify --strict --all-architectures "$bundle"
echo "Passed signing checks for identical builds, compatible updates, incompatible updates, missing certificates, running apps, and explicit migration."

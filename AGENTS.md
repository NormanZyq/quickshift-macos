# Maintainer notes

These notes apply to this repository. Keep operational constraints and regression context here rather than turning the README into a development journal.

## Documentation

- `README.md` is the default English entry point; `README.zh-CN.md` is its Chinese counterpart. Keep capabilities, commands, limitations, and links aligned.
- Both READMEs use the `HEADER_ICON`, `TOOL_PHILOSOPHY`, and `SHORTCUT_PHILOSOPHY` header slots. Keep the shared icon and the user-provided introduction and shortcut rationale aligned across languages. The README icon is `Resources/AppIcon.png`; regenerate it together with `Resources/AppIcon.icns` using `scripts/make-icon.swift`. Use `--preview-dir .build/icon-review` to inspect the exported sizes. Keep visual review artifacts in `.build/`.
- Keep public documentation focused on installation, observable behavior, configuration, development commands, and actionable troubleshooting. Do not include session state, debugging chronology, experiment results, or claims inferred only from unit tests.
- Documentation-only changes need link, structure, and command-path checks; they do not require rebuilding or reauthorizing the running app.

## Input engine constraints

- The production event callback lives in `Sources/InputSafety/InputSafety.c`. It must not enter Swift or AppKit, acquire locks, make synchronous window/GUI calls, perform file I/O, or wait for the main loop.
- Keep configuration reads atomic, action delivery bounded, and pipe writes nonblocking. Capture the foreground PID with the action; matched input must not activate the application under the pointer.
- External window movement uses a separate serial AX queue. Self-directed window movement must use `NSWindow` on the main actor: same-process AX can invoke AppKit directly on its calling thread and crash from the AX worker. Do not move external AX IPC into the input callback or the main loop.
- Keep the action pipe's `.main` dispatch-source handler explicitly `@Sendable` and unwrap weak `self` into an immutable reference before `MainActor.assumeIsolated`. CI's Swift 6.1.2 rejects the unannotated nested weak capture even though newer toolchains accept it. Preserve main-actor delivery without adding a synchronous main-queue hop to the C input callback.
- Preserve the system Force Quit chord, captured press/drag/release handling, repeat suppression, and explicit pause/restart behavior.
- Callback and worker watchdogs operate independently of the UI. Main-loop recovery applies only when move actions remain pending for their full wait budget; a stale idle heartbeat alone is not a failure.
- Recovery must not depend on the stalled thread cleaning itself up. Keep the immediate safety-exit path free of logging and file operations; preserve previous fault state on a later startup.

## Builds and app identity

- Use `scripts/build-app.sh` to assemble and sign a fresh bundle. Quit the target app before replacing it; closing its settings window leaves the process running. Never overwrite a loaded executable in place.
- Keep the signing channel and bundle identifier `local.quickshiftdisplay.app` stable across updates. Configure `quickshift.signingIdentity` locally in Git or supply `SIGNING_IDENTITY`. The unconfigured fallback is ad hoc. Incompatible updates require an explicit `QUICKSHIFT_ALLOW_IDENTITY_CHANGE=1` migration. Test candidates at a separate path and refresh only QuickShift's Accessibility grant during an intentional migration.
- Use an explicit app path when multiple builds share the bundle identifier. Candidate output is configurable with `QUICKSHIFT_APP_PATH`.
- Keep `.build/`, `.swiftpm/`, `dist/`, and `.DS_Store` out of Git. The checked-in icon is an application resource; app bundles, archives, native probe binaries, and local diagnostics are build outputs.
- The user's shortcut enablement preference must survive normal restarts, engine updates, permission changes, and diagnostic launches. Keep temporary runtime suspension separate from the saved checkbox; only an explicit user preference change should rewrite it. Actual input safety faults still require an explicit listener restart.
- Login item registration uses `SMAppService.mainApp` as the source of truth. Do not mirror it into a preference that can override changes made in System Settings. Tests must use the injected login service, not register real login items.

## Validation

- `.github/workflows/release.yml` is a manual-only release path. Build the requested revision at its resolved full SHA; run release tooling from the workflow revision. Do not add push/tag publishing without an explicit request.
- Keep source execution, Apple credential handling, and release write access in separate jobs. Import Apple keys only into the disposable signing job and remove its temporary keychain and key files, including on failure.
- Release archives must contain both architectures and match the selected source's bundle version. Verify checksums and metadata after artifact transfer. Refuse existing releases and conflicting tags; assemble attachments in a draft before publishing.
- Changes to release helpers require their isolated Python tests and workflow syntax checks. These tests use fake API responses and disposable archives. On macOS they also compile and ad hoc sign disposable Mach-O fixtures to check architecture validation; never launch these fixtures. Tests must not publish releases, access signing credentials, or modify the installed app.
- Signing regression checks must match `build-app.sh`'s own failure diagnostics. Apple's `codesign` error wording differs between macOS versions; macOS 15 can omit the requested identity from its missing-keychain error. Preserve the native exit code and verify the previous bundle remains intact.
- For the running-app guard test, compile a disposable executable and wait for it to signal readiness. A copied and re-signed macOS system binary can terminate before the test reaches the guard.

The normal checks are documented in the README. In a restricted development environment, keep compiler and SwiftPM caches inside the repository:

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
swift test --disable-sandbox --cache-path .build/cache

python3 scripts/test-watchdog.py
```

- Automated input tests construct events in memory; watchdog tests run child processes. These checks must not install a global filter or post input.
- Verify pending-action deadline selection with fixed timestamps in `pending-tail-advances`. Keep the armed tests for actual stalled workers and pending work, including `main-stall` and `busy-main-stall`.
- For cross-process checks, use `Tests/Fixtures/WindowProbe.swift` and the `--test-target-pid` mode. Reject invalid targets rather than falling back to a global filter.
- Scoped mouse events must continue to reach the probe after each move, so the pointer must follow its new position. This differs from global mode, where the pointer can stay anywhere.
- Do not assume automation-generated input reaches a session-level event tap. Confirm action/event counters and use physical input when necessary.
- Probe screen names and trace paths can contain intermediate states during animation or display reconnection. Check settled coordinates and received input counts rather than interpreting every trace entry as a completed move.
- Diagnostics should run in a logged-in graphical session. The diagnostic process's Accessibility status is separate from the menu bar process's authorization. Safety state is stored under the user's `Library/Caches/QuickShift` directory; the previous fault is retained separately.

## Regression context

- The 1.2.0 changes have 38 Swift tests plus the 7 watchdog cases. Normal application relaunch was checked with shortcut enablement both on and off; system login-item registration, cancellation, and persistence were checked independently. Physical shortcuts moving QuickShift's own settings window were confirmed without exit or input disruption. A real logout/login is not part of this verification.
- Early input implementations caused system input blocking. Retain the C callback and independent recovery boundaries above when changing shortcut handling.
- An unconditional main-loop heartbeat check caused a protective exit with code `73` around display wake. Preserve the `idle-main-pause` and `main-resumes-with-work` watchdog cases as well as the pending-work stall case. Exit codes `71`–`75` correspond to fault codes `1`–`5`.
- The 1.1.1 baseline passed 28 Swift tests and 7 watchdog cases. Physical global shortcut use was confirmed with normal system input; a recorded run had 16 actions and no safety fault. These are baseline observations, not a guarantee of long-duration sleep/wake stability, which still needs real-world coverage.
- A window that filled one display may not expand to the full width of another. Do not claim universal maximized-window fitting from pure geometry tests; verify the destination app's actual frame after movement.

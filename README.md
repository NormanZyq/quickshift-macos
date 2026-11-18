<!-- HEADER_ICON_START -->

<!-- HEADER_ICON_END -->

# QuickShift

[English](README.md) | [简体中文](README.zh-CN.md)

<!-- TOOL_PHILOSOPHY_START -->

<!-- TOOL_PHILOSOPHY_END -->

<!-- SHORTCUT_PHILOSOPHY_START -->

<!-- SHORTCUT_PHILOSOPHY_END -->

A native macOS menu bar utility for moving the active window between displays.

[For users](#for-users) · [For developers](#for-developers) · [Troubleshooting](#troubleshooting)

## For users

### Features

- Move the active window to the display on its left or right, wherever the pointer is.
- Customize each direction with a modifier + mouse button or keyboard shortcut.
- Enable wraparound to cycle through displays, or stop at the edges.
- Keep a window's size and relative position where possible, with adjustments for smaller displays.
- Pause shortcuts, change settings, and quit from the menu bar.
- Restore your shortcut enablement choice on restart, with optional launch at login.

### Installation

Requires **macOS 13 or later** and at least **two displays in extended desktop mode**. Mirrored displays share a workspace and do not provide separate destinations.

- **Packaged app:** download the universal ZIP from this repository's **Releases** page, extract it, and move `QuickShift.app` to your Applications folder. Check the release notes for its signing and notarization status.
- **From source:** [build the app](#build-from-source), then move `dist/QuickShift.app` to your Applications folder.

Open QuickShift from its installed location before granting permissions.

### Quick start

1. In QuickShift, click **Open Accessibility Settings…** (`打开辅助功能设置…`) and enable QuickShift in macOS System Settings.
2. Enable **Global Shortcuts** (`启用全局快捷键`) in QuickShift settings.
3. Focus a regular app window and use the shortcuts below.

The app's controls currently use Chinese labels; the corresponding labels are included here where needed.

### Default shortcuts

| Action | Shortcut |
| --- | --- |
| Move to the left display | Control + Command + Shift + left mouse click |
| Move to the right display | Control + Command + Shift + right mouse click |

The shortcut moves the **active window**. Matching clicks are captured to preserve the current app's focus and prevent context menus.

**Wraparound is enabled by default:** moving left from the leftmost display goes to the rightmost display, and vice versa.

### Customize shortcuts and behavior

Open the menu bar icon → **Settings…** (`设置…`).

1. Click the shortcut for the direction you want to change.
2. Hold one or more modifiers—Control, Option, Shift, or Command—and press a key, or click a mouse button inside the recording area.
3. Click **Save** (`保存`).

Each direction needs a different shortcut. Modifier matching is exact: an extra Option key, for example, will not trigger the default shortcut. Caps Lock, Fn, and numeric keypad flags do not affect matching. Keyboard shortcuts follow physical key positions.

Turn **Wraparound** (`循环切换显示器`) off to stop at either edge. Preferences are saved automatically. With Accessibility permission granted, an enabled shortcut switch resumes listening on the next normal launch; a disabled switch stays disabled. Closing the settings window keeps QuickShift running in the menu bar; use its **Quit** command to exit.

### Launch at login

Enable **Launch at Login** (`登录时启动`) in settings to open QuickShift when you sign in to macOS. Disable it to remove the login item. This option is off by default and is independent of the global shortcuts switch.

If macOS requires approval, click **Open Login Items Settings…** (`打开登录项设置…`) and allow QuickShift. The app reflects the status managed by macOS, including changes made in System Settings.

### Window behavior

- Displays are ordered from left to right using their positions in macOS. Displays with the same horizontal center are ordered from top to bottom.
- For a window spanning multiple displays, the display with the largest overlap is its starting display.
- Window size and relative position are preserved where possible. Resizable windows can shrink to fit the destination's available desktop area, respecting the menu bar and Dock.
- Display connections and arrangement changes are picked up automatically.
- Native macOS full-screen windows must leave full screen before moving. QuickShift works with desktop windows and does not switch Spaces.

### Permissions and privacy

QuickShift uses **Accessibility** permission to control windows. It does not require Screen Recording permission, send network requests, or log the contents of your keystrokes. Preferences are stored locally.

Disabling shortcuts removes the global input listener. New installations start with shortcuts disabled; subsequent launches restore your saved choice. A diagnostic or protective pause keeps that choice intact; use **Restart Listener** (`重新启动监听`) to resume. Command + Option + Esc remains reserved for the system's Force Quit command.

## For developers

### Build from source

Use Xcode or Command Line Tools with **Swift 6**. The project is a Swift package with no third-party dependencies; open `Package.swift` in Xcode or build from the repository root:

```bash
bash scripts/build-app.sh
open dist/QuickShift.app --args --paused
```

The script builds a release app for the current Mac's architecture, bundles its resources, signs it, and writes `dist/QuickShift.app`.

Quit an existing QuickShift instance from its menu before rebuilding the same app path. Closing its settings window does not quit the process.

### Build options and signing

Build a universal app for Apple Silicon and Intel:

```bash
bash scripts/build-app.sh --arch arm64 --arch x86_64
```

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `CONFIGURATION` | `release` | Swift build configuration, such as `debug` or `release`. |
| `QUICKSHIFT_APP_PATH` | `<repository>/dist/QuickShift.app` | Output app location; use an absolute path for a custom location. |
| `SIGNING_IDENTITY` | `quickshift.signingIdentity` from Git config, then `-` | Override the signing identity for one build. |
| `QUICKSHIFT_ALLOW_IDENTITY_CHANGE` | `0` | Set to `1` for an intentional replacement with an incompatible identity. |

#### Keep Accessibility access across updates

For personal use, create an **Apple Development** certificate in Xcode Settings → Accounts → Manage Certificates. For direct distribution, use **Developer ID Application** from your Apple Developer Program team. Choose the signing channel you intend to keep. Copy the exact identity name from the first command and save it once in this checkout.

```bash
security find-identity -v -p codesigning
git config --local quickshift.signingIdentity 'Apple Development: Your Name (ID)'
bash scripts/build-app.sh
```

macOS records Accessibility consent against the app's code identity. For normal updates, keep the bundle identifier, signing identity and installation path consistent. The build checks both versions against each other's designated requirements before replacing the previous app. An incompatible build stops with the original intact. To build alongside it, use `QUICKSHIFT_APP_PATH="$PWD/dist/preview/QuickShift.app" bash scripts/build-app.sh`. [Apple on code identity and privacy grants](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)

An existing ad hoc grant is tied to that build's code hash. When migrating an installed ad hoc copy to your configured certificate, quit QuickShift, run `QUICKSHIFT_ALLOW_IDENTITY_CHANGE=1 bash scripts/build-app.sh`, and grant Accessibility to the new copy once. Subsequent builds use the saved identity. Developer ID builds use the hardened runtime and a secure timestamp. Public distribution also requires a separate notarization step for the standard Gatekeeper experience. [Apple's notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

### GitHub Releases

The [release workflow](.github/workflows/release.yml) runs only when manually dispatched. Push it to the repository's default branch, then open **Actions → Build and release → Run workflow**. The workflow must exist on the default branch for GitHub to offer manual runs. [GitHub's manual workflow guide](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)

| Input | Behavior |
| --- | --- |
| `source_ref` | Commit SHA, branch, or tag to build. Prefer a full commit SHA; leaving it blank builds the selected workflow branch's commit. |
| `release_tag` | New tag such as `v1.2.1` or `v1.2.1-rc.1`. Its version must match `CFBundleShortVersionString` in the selected commit's `Resources/Info.plist`. |
| `signing` | `ad-hoc` requires no Apple credentials. `developer-id` signs and notarizes using the secrets below. |
| `draft` | Leave the completed release as a draft instead of publishing it. Off by default. |
| `prerelease` | Mark the release as a prerelease. Off by default; a tag suffix does not enable it automatically. |

The workflow tests the selected source, builds a universal app for Apple Silicon and Intel, and creates these Release attachments:

- `QuickShift-<tag>-macOS-universal.zip`
- `SHA256SUMS.txt`
- `build-info.json`, recording the exact source commit, app version, architectures, signing channel, and workflow run
- `release-notes.md`, also used as the release description

All attachments are uploaded before publishing. An existing release is never replaced; an existing tag is accepted only when it points to the selected commit. Update the version in `Resources/Info.plist` before tagging a new app version. The workflow does not rewrite source files or move tags.

For normal releases from the default branch, the built-in `GITHUB_TOKEN` is sufficient; only the publish job requests `contents: write`. Repository or organization policy must allow GitHub Actions and these permissions. Release tooling comes from the workflow revision, while the app is built from `source_ref`.

If a target commit changes workflow files relative to the default branch, GitHub can require workflow write permission when creating its release or tag. For that case, optionally configure the repository secret `RELEASE_TOKEN` with a fine-grained token restricted to this repository and **Contents: Read and write** plus **Workflows: Read and write**. Only the publish step uses it. [GitHub's release API permissions](https://docs.github.com/en/rest/releases/releases#create-a-release)

#### Optional Developer ID signing and notarization

For the `developer-id` channel, add these **repository Actions secrets** in **Settings → Secrets and variables → Actions**. An Apple Developer Program membership, a Developer ID Application certificate with its private key, and a team App Store Connect API key with notarization access are required.

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Base64 contents of a `.p12` export containing exactly one valid **Developer ID Application** signing identity and its private key. |
| `MACOS_CERTIFICATE_PASSWORD` | The nonempty password used for the `.p12` export. |
| `APPLE_NOTARY_KEY_ID` | App Store Connect team API key ID. |
| `APPLE_NOTARY_ISSUER_ID` | The API key's issuer ID. |
| `APPLE_NOTARY_PRIVATE_KEY` | Complete contents of the API key's `.p8` file, including its header and footer. |

The signing job imports the certificate into a temporary keychain, submits the app to Apple, staples the accepted notarization ticket, and recreates the ZIP and checksums. It removes the imported credentials afterward. Use the same signing channel and team for subsequent updates to keep a consistent app identity.

The default `ad-hoc` channel skips Apple signing and notarization; macOS may require explicit approval to open it, and an update can require renewed Accessibility permission. Verify downloaded attachments together:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

### Tests

Run the Swift suite and the native watchdog checks from the repository root. The watchdog checks also require Python 3.

```bash
swift test
python3 scripts/test-watchdog.py
bash scripts/test-signing.sh
python3 -m unittest discover -s scripts/ci/tests -p 'test_*.py'
```

The suites cover display navigation and placement, shortcut validation and persistence, startup preferences, local and external window routing, login item state, input matching and release handling, and watchdog recovery. Swift tests use in-memory events and simulated login services; watchdog checks use isolated subprocesses. Neither installs an event tap or posts system input.

Run `python3 scripts/test-watchdog.py --idle-cost` to measure the idle input engine for 30 seconds. The probe uses a private Mach port and reports CPU percentage, thread count, and context switches per second.

The signing checks build disposable copies and verify compatible replacements, refusal of incompatible updates or missing certificates, and protection of a running executable.

### Development test window

Build and open the disposable window used for cross-process window movement checks:

```bash
mkdir -p .build
bash scripts/build-window-probe.sh
open .build/QuickShiftProbe.app
```

The window displays its screen, coordinates, dimensions, and received input count. Its state is written to `.build/probe-state.json`. A consumed shortcut should move the window without increasing that count.

To limit the listener to this test process, quit QuickShift, then replace `12345` with the `processID` from the state file:

```bash
open dist/QuickShift.app --args --test-target-pid 12345 --paused
```

Enable shortcuts in the app to begin. This mode accepts only the QuickShiftProbe process; an invalid target never falls back to global listening. With a physical mouse, follow the test window after each move so subsequent clicks still reach it. Normal global mode does not have this pointer restriction.

### Project layout

| Path | Responsibility |
| --- | --- |
| [`Sources/QuickShiftCore`](Sources/QuickShiftCore) | Display geometry, navigation, preferences, and shortcut matching. |
| [`Sources/InputSafety`](Sources/InputSafety) | Native event thread, atomic configuration, action queue, and watchdog. |
| [`Sources/QuickShiftDisplay`](Sources/QuickShiftDisplay) | AppKit interface, login items, local window movement on the main actor, and an Accessibility worker for external apps. |
| [`Tests`](Tests) | Swift tests and native test fixtures. |
| [`scripts`](scripts) | App and test-window builds, icon generation, and watchdog checks. |
| [`.github/workflows/release.yml`](.github/workflows/release.yml), [`scripts/ci`](scripts/ci) | Manual universal builds, release packaging, optional notarization, and publishing. |

Build outputs and local diagnostics in `.build/` and `dist/` are excluded from Git. Maintenance guidelines are documented in [`AGENTS.md`](AGENTS.md).

## Troubleshooting

| Problem | What to do |
| --- | --- |
| Nothing moves | Confirm Accessibility permission, enable shortcuts, focus a regular window, and check that at least two extended displays are connected. |
| Permission stops working after replacing the app | Check the signing identity and open the installed copy. After an intentional identity change, enable that copy in Accessibility. If macOS still lists only the old grant, remove the old QuickShift entry, then add the installed copy. See [signing for updates](#keep-accessibility-access-across-updates). |
| Permission is granted but the listener is not ready | Use **Check Input Monitoring…** (`检查输入监控…`) if shown in QuickShift settings, then quit and reopen the app. |
| The saved switch is on, but listening is paused | Check the status in settings. Use **Restart Listener** after a diagnostic or protective pause. For an unexpected exit, include a [diagnostic report](#diagnostic-report). |
| Launch at login is waiting for approval | Use **Open Login Items Settings…** in QuickShift and allow the app in macOS. The shortcut switch is restored separately when it launches. |
| A shortcut does not trigger | Check the exact modifier combination and conflicts with system shortcuts or other tools. Secure input fields can restrict event access. |
| A full-screen window or a particular app will not move | Leave native full screen first. The target app must expose a movable window through macOS Accessibility. |
| A previously filled window does not fill the destination | Resize it after moving. Full-width or full-height expansion is not guaranteed, and apps can enforce their own size limits. |
| The build script says QuickShift is running | Quit from the QuickShift menu bar menu, then rerun the build. |
| macOS blocks a packaged app | The default build is ad hoc signed and not notarized. Follow [Apple's instructions for opening apps on your Mac](https://support.apple.com/en-us/102445) for the relevant alert. |
| **Run workflow** is missing | Push the release workflow to the repository's default branch and check Actions access. See [GitHub Releases](#github-releases). |
| A release run rejects the tag or a previous attempt left a draft | Use a tag matching the selected app version. For an existing tag, select its exact commit. Remove a failed draft before retrying that tag, or choose a new version suffix; published releases are not overwritten. |

### Diagnostic report

For an app installed in Applications:

```bash
/Applications/QuickShift.app/Contents/MacOS/QuickShiftDisplay --diagnostics
```

For a source build, use `dist/QuickShift.app/Contents/MacOS/QuickShiftDisplay --diagnostics` instead.

The report includes display geometry, the last recorded input engine state, counters, callback duration, and a previous safety exit when available. It does not include keystroke contents. `diagnosticProcessAccessibilityTrusted` describes the command-line process; check the running app's settings for its permission status.

| Fault code | Meaning |
| --- | --- |
| `0` | No safety fault recorded. |
| `1` | Input callback stalled. |
| `2` | Event loop stalled. |
| `3` | Pending move actions were not delivered to the main loop. |
| `4` | macOS reported an event tap timeout. |
| `5` | The action queue overflowed. |

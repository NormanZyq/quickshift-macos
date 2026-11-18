import AppKit
@preconcurrency import ApplicationServices
import QuickShiftCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = SettingsStore()
    private let inputTargetPID = AppDelegate.testTargetProcessID()
    private lazy var monitor = GlobalShortcutMonitor(targetProcessID: inputTargetPID)
    private let mover = WindowMover()
    private let loginItems = LoginItemController()
    private var runtimeState = ShortcutRuntimeState()
    private let notice = NoticeController()
    private var settings: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private let permissionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let displayItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "启用快捷键", action: nil, keyEquivalent: "")
    private let wrapItem = NSMenuItem(title: "循环切换显示器", action: nil, keyEquivalent: "")
    private let leftItem = NSMenuItem(title: "向左移动当前窗口", action: nil, keyEquivalent: "")
    private let rightItem = NSMenuItem(title: "向右移动当前窗口", action: nil, keyEquivalent: "")
    private var screenObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var systemSettingsWasActive = false
    private var pendingGrantTimer: Timer?
    private var permissionCheckDeadline: ContinuousClock.Instant?
    private var menuProcessID: pid_t?
    private var trusted = false
    private var displays: [DisplayInfo] = []

    private static func testTargetProcessID() -> pid_t {
        guard let index = CommandLine.arguments.firstIndex(of: "--test-target-pid") else { return 0 }
        guard index + 1 < CommandLine.arguments.count,
              let pid = Int32(CommandLine.arguments[index + 1]), pid > 0,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "local.quickshiftdisplay.probe" else { return -1 }
        return pid
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtimeState = ShortcutRuntimeState(forcePaused: CommandLine.arguments.contains("--paused"),
                                            testMode: inputTargetPID != 0,
                                            previousSafetyFault: GlobalShortcutMonitor.lastStatus()?.fault ?? 0)
        buildMenu()
        monitor.preferences = store.preferences
        let foreground = NSWorkspace.shared.frontmostApplication
        monitor.foregroundProcessID = foreground?.processIdentifier
        systemSettingsWasActive = foreground?.bundleIdentifier == "com.apple.systempreferences"
        monitor.onShortcut = { [weak self] direction, processID in self?.move(direction, processID: processID) }
        monitor.onUnexpectedStop = { [weak self] in self?.refreshRuntime() }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let processID = app?.processIdentifier
            let systemSettingsIsActive = app?.bundleIdentifier == "com.apple.systempreferences"
            MainActor.assumeIsolated {
                guard let self else { return }
                self.monitor.foregroundProcessID = processID
                let returnedFromSettings = self.systemSettingsWasActive && !systemSettingsIsActive
                self.systemSettingsWasActive = systemSettingsIsActive
                if returnedFromSettings {
                    self.permissionCheckDeadline = nil
                    self.refreshRuntime()
                }
                else if systemSettingsIsActive { self.updatePendingGrantTimer() }
            }
        }
        store.onChange = { [weak self] in
            guard let self else { return }
            let wasEnabled = monitor.preferences.isEnabled
            monitor.preferences = store.preferences
            if !wasEnabled && store.preferences.isEnabled {
                runtimeState.resume()
                monitor.resetSuspensionForUserRequest()
            }
            settings?.refreshPreferences()
            refreshRuntime()
        }
        displays = ScreenSnapshot.current()
        refreshRuntime()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.displays = ScreenSnapshot.current()
                self.refreshMenu()
                self.refreshSettingsStatus()
            }
        }
        let hasLaunched = UserDefaults.standard.bool(forKey: "hasLaunched")
        UserDefaults.standard.set(true, forKey: "hasLaunched")
        if runtimeState.shouldOpenSettings(hasLaunched: hasLaunched, userEnabled: store.preferences.isEnabled, trusted: trusted) {
            showSettings()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if settings?.window?.isVisible == true { refreshRuntime() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        pendingGrantTimer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        refreshRuntime()
    }

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "QuickShift 移屏")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "QuickShift · 在显示器之间移动当前窗口"
        item.menu = statusMenu
        statusItem = item
        statusMenu.delegate = self
        statusMenu.autoenablesItems = false
        permissionItem.isEnabled = false
        displayItem.isEnabled = false
        enabledItem.target = self
        enabledItem.action = #selector(toggleEnabled)
        wrapItem.target = self
        wrapItem.action = #selector(toggleWrap)
        leftItem.target = self
        leftItem.action = #selector(moveLeft)
        rightItem.target = self
        rightItem.action = #selector(moveRight)
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        let restartItem = NSMenuItem(title: "重新启动快捷键监听", action: #selector(restartMonitor), keyEquivalent: "")
        restartItem.target = self
        let quitItem = NSMenuItem(title: "退出 QuickShift", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        [permissionItem, displayItem, .separator(), leftItem, rightItem, .separator(), enabledItem, wrapItem,
         .separator(), settingsItem, restartItem, quitItem].forEach { statusMenu.addItem($0) }

        // Supply native application commands while the settings window has focus.
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "QuickShift")
        appMenu.addItem(settingsItem.copy() as! NSMenuItem)
        appMenu.addItem(.separator())
        appMenu.addItem(quitItem.copy() as! NSMenuItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
    }

    private func refreshRuntime() {
        trusted = AXIsProcessTrusted()
        if runtimeState.shouldListen(userEnabled: store.preferences.isEnabled, trusted: trusted) {
            monitor.start()
        } else { monitor.stop() }
        refreshMenu()
        refreshSettingsStatus()
        updatePendingGrantTimer()
    }

    private func updatePendingGrantTimer() {
        // A grant can arrive while System Settings still has focus. Stop checking
        // as soon as it succeeds or the user leaves the permission workflow.
        if trusted { permissionCheckDeadline = nil }
        guard systemSettingsWasActive, let permissionCheckDeadline, .now < permissionCheckDeadline else {
            pendingGrantTimer?.invalidate()
            pendingGrantTimer = nil
            return
        }
        guard pendingGrantTimer == nil else { return }
        pendingGrantTimer = Timer.scheduledTimer(timeInterval: 2.5, target: self,
            selector: #selector(checkPendingGrant), userInfo: nil, repeats: false)
        pendingGrantTimer?.tolerance = 0.5
    }

    @objc private func checkPendingGrant() {
        pendingGrantTimer = nil
        if AXIsProcessTrusted() { refreshRuntime() } else { updatePendingGrantTimer() }
    }

    private func refreshMenu() {
        permissionItem.title = !store.preferences.isEnabled ? "快捷键已暂停" : (!trusted ? "需要辅助功能权限" : (monitor.isRunning ? "QuickShift 已就绪" : "输入监听已暂停"))
        displayItem.title = "已连接 \(displays.count) 台显示器"
        enabledItem.state = store.preferences.isEnabled ? .on : .off
        wrapItem.state = store.preferences.wrapsDisplays ? .on : .off
        leftItem.title = "向左移动   \(store.preferences.left.title)"
        rightItem.title = "向右移动   \(store.preferences.right.title)"
        leftItem.isEnabled = trusted
        rightItem.isEnabled = trusted
    }

    private func refreshSettingsStatus() {
        guard let settings, settings.window?.isVisible == true else { return }
        settings.refreshStatus(trusted: trusted, listening: monitor.isRunning, displays: displays,
                               safelySuspended: monitor.isSafelySuspended, testOnly: inputTargetPID != 0,
                               startupSuspension: runtimeState.suspension?.explanation)
        settings.refreshLoginItemStatus(loginItems.status, errorMessage: loginItems.errorMessage)
    }

    private func move(_ direction: MoveDirection, processID: pid_t?) {
        guard AXIsProcessTrusted() else { showSettings(); return }
        guard let pid = inputTargetPID == 0 ? processID : inputTargetPID, pid > 0 else {
            notice.show(MoveFailure.noWindow.localizedDescription)
            return
        }
        // Use the PID captured with this action. Refresh geometry because the Dock can change the visible frame.
        let currentDisplays = ScreenSnapshot.current()
        mover.move(processID: pid, direction: direction, displays: currentDisplays, wraps: store.preferences.wrapsDisplays) { [weak self] result in
            if case let .failure(error) = result { self?.notice.show(error.localizedDescription) }
        }
    }

    @objc private func showSettings() {
        if settings == nil {
            let controller = SettingsWindowController(store: store, testOnly: inputTargetPID != 0)
            controller.onClose = { [weak self] in self?.settings = nil }
            controller.onRequestAccessibility = { [weak self] in self?.requestAccessibility() }
            controller.onRequestInputMonitoring = {
                _ = CGRequestListenEventAccess()
                Self.openPrivacyPane("Privacy_ListenEvent")
            }
            controller.onRecordingChanged = { [weak self] in self?.monitor.isRecording = $0 }
            controller.onRestartMonitoring = { [weak self] in self?.restartMonitor() }
            controller.onSetLoginItemEnabled = { [weak self] enabled in
                guard let self else { return }
                loginItems.setEnabled(enabled)
                refreshSettingsStatus()
            }
            controller.onRequestLoginItemSettings = { [weak self] in self?.loginItems.openSettings() }
            settings = controller
        }
        settings?.refreshPreferences()
        settings?.showWindow(nil)
        refreshRuntime()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func requestAccessibility() {
        if !AXIsProcessTrusted() {
            permissionCheckDeadline = .now.advanced(by: .seconds(60))
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        Self.openPrivacyPane("Privacy_Accessibility")
        updatePendingGrantTimer()
    }

    private static func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleEnabled() { store.update { $0.isEnabled.toggle() } }
    @objc private func toggleWrap() { store.update { $0.wrapsDisplays.toggle() } }
    @objc private func moveLeft() { move(.left, processID: menuProcessID) }
    @objc private func moveRight() { move(.right, processID: menuProcessID) }
    @objc private func restartMonitor() {
        runtimeState.resume()
        monitor.resetSuspensionForUserRequest()
        refreshRuntime()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

import AppKit
import Testing
@testable import QuickShiftDisplay

@Test @MainActor func enabledPreferenceRestoresAtNormalStartupWithAuthorization() throws {
    let domain = "QuickShift-startup-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let store = SettingsStore(defaults: defaults)
    #expect(!store.preferences.isEnabled)
    store.update { $0.isEnabled = true }
    // Legacy launch metadata must no longer rewrite an explicit preference.
    defaults.set(false, forKey: "lastRunEndedCleanly")
    defaults.set(0, forKey: "inputEngineRevision")
    defaults.set("test:12345", forKey: "inputScope")
    let relaunched = SettingsStore(defaults: defaults)
    #expect(relaunched.preferences.isEnabled)
    #expect(ShortcutRuntimeState().shouldListen(userEnabled: relaunched.preferences.isEnabled, trusted: true))
}

@Test @MainActor func disabledPreferenceStaysDisabledAfterRelaunch() throws {
    let domain = "QuickShift-startup-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let store = SettingsStore(defaults: defaults)
    store.update { $0.isEnabled = true }
    store.update { $0.isEnabled = false }
    let relaunched = SettingsStore(defaults: defaults)
    #expect(!relaunched.preferences.isEnabled)
    #expect(!ShortcutRuntimeState().shouldListen(userEnabled: relaunched.preferences.isEnabled, trusted: true))
}

@Test func authorizationGatesListeningWithoutChangingSavedIntent() {
    let runtime = ShortcutRuntimeState()
    #expect(!runtime.shouldListen(userEnabled: true, trusted: false))
    #expect(runtime.shouldListen(userEnabled: true, trusted: true))
    #expect(!runtime.shouldListen(userEnabled: false, trusted: true))
}

@Test func loginKeepsPausedShortcutsQuietButSurfacesSetupAndRecovery() {
    let normal = ShortcutRuntimeState()
    #expect(!normal.shouldOpenSettings(hasLaunched: true, userEnabled: false, trusted: false))
    #expect(!normal.shouldOpenSettings(hasLaunched: true, userEnabled: true, trusted: true))
    #expect(normal.shouldOpenSettings(hasLaunched: false, userEnabled: false, trusted: false))
    #expect(normal.shouldOpenSettings(hasLaunched: true, userEnabled: true, trusted: false))
    #expect(ShortcutRuntimeState(previousSafetyFault: 2).shouldOpenSettings(hasLaunched: true, userEnabled: false, trusted: true))
}

@Test @MainActor func settingsFooterRemainsReachableOnShortDisplays() throws {
    _ = NSApplication.shared
    let controller = SettingsWindowController(store: SettingsStore())
    let window = try #require(controller.window)
    let scroll = try #require(window.contentView as? NSScrollView)
    let document = try #require(scroll.documentView)
    window.setContentSize(NSSize(width: 600, height: 390))
    controller.refreshStatus(trusted: false, listening: false, displays: [])
    scroll.layoutSubtreeIfNeeded()
    #expect(document.frame.height > scroll.contentSize.height)
    #expect(abs(document.frame.width - scroll.contentSize.width) < 1)
    let footer = try #require(document.subviews.compactMap { $0 as? NSStackView }.first?.arrangedSubviews.last)
    document.scrollToVisible(footer.convert(footer.bounds, to: document))
    #expect(scroll.documentVisibleRect.contains(footer.convert(footer.bounds, to: document)))
}

@Test @MainActor func temporaryStartupSuspensionDoesNotDisableTheSavedPreference() throws {
    let domain = "QuickShift-startup-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let store = SettingsStore(defaults: defaults)
    store.update { $0.isEnabled = true }
    for var runtime in [ShortcutRuntimeState(forcePaused: true), ShortcutRuntimeState(testMode: true),
                        ShortcutRuntimeState(previousSafetyFault: 3)] {
        #expect(!runtime.shouldListen(userEnabled: store.preferences.isEnabled, trusted: true))
        #expect(SettingsStore(defaults: defaults).preferences.isEnabled)
        runtime.resume()
        #expect(runtime.shouldListen(userEnabled: store.preferences.isEnabled, trusted: true))
        #expect(!runtime.shouldListen(userEnabled: false, trusted: true))
    }
    #expect(ShortcutRuntimeState().shouldListen(userEnabled: SettingsStore(defaults: defaults).preferences.isEnabled, trusted: true))
}

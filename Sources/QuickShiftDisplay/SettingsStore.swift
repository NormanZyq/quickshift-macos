import AppKit
import QuickShiftCore

@MainActor
final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "preferences.v1"
    var onChange: (() -> Void)?

    private(set) var preferences: AppPreferences

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode(AppPreferences.self, from: data), stored.isValid {
            preferences = stored
        } else {
            preferences = AppPreferences()
        }
    }

    func update(_ body: (inout AppPreferences) -> Void) {
        var next = preferences
        body(&next)
        guard next.isValid, next != preferences else { return }
        preferences = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: key) }
        onChange?()
    }

    func resetShortcuts() {
        update {
            $0.left = AppPreferences().left
            $0.right = AppPreferences().right
        }
    }
}

extension ShortcutModifiers {
    init(_ flags: CGEventFlags) {
        self = []
        if flags.contains(.maskControl) { insert(.control) }
        if flags.contains(.maskAlternate) { insert(.option) }
        if flags.contains(.maskShift) { insert(.shift) }
        if flags.contains(.maskCommand) { insert(.command) }
    }

    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
    }
}

@MainActor
enum ScreenSnapshot {
    static func current() -> [DisplayInfo] {
        let screens = NSScreen.screens
        // The first NSScreen is the primary screen, not necessarily NSScreen.main (keyboard focus).
        let primaryTop = screens.first?.frame.maxY ?? 0
        return DisplayLayout.ordered(screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return DisplayInfo(
                id: number.uint32Value, name: screen.localizedName,
                frame: DisplayLayout.accessibilityRect(fromAppKit: screen.frame, primaryTop: primaryTop),
                visibleFrame: DisplayLayout.accessibilityRect(fromAppKit: screen.visibleFrame, primaryTop: primaryTop)
            )
        })
    }
}

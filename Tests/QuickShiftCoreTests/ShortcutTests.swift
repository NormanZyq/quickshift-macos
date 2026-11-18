import Foundation
import Testing
@testable import QuickShiftCore

@Test func defaultsMatchRequestedMouseCombinations() {
    let preferences = AppPreferences()
    #expect(preferences.isValid)
    #expect(preferences.wrapsDisplays)
    #expect(preferences.direction(modifiers: [.control, .command, .shift], trigger: .mouse(button: 0)) == .left)
    #expect(preferences.direction(modifiers: [.control, .command, .shift], trigger: .mouse(button: 1)) == .right)
    #expect(preferences.direction(modifiers: [.control, .command, .shift, .option], trigger: .mouse(button: 0)) == nil)
    #expect(preferences.direction(modifiers: [], trigger: .mouse(button: 0)) == nil)
}

@Test func preferencesRoundTripWithoutLosingCustomShortcuts() throws {
    var preferences = AppPreferences(wrapsDisplays: false, isEnabled: false, animatesWindowMoves: true)
    preferences.left = Shortcut(modifiers: [.control, .option], trigger: .key(code: 123, label: "←"))
    let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))
    #expect(restored == preferences)
    #expect(restored.isValid)
}

@Test func preAnimationPreferencesKeepTheirBindingsAndEnablement() throws {
    let original = AppPreferences(left: Shortcut(modifiers: .option, trigger: .key(code: 123, label: "←")),
                                  right: Shortcut(modifiers: .control, trigger: .mouse(button: 4)),
                                  wrapsDisplays: false, isEnabled: true)
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    legacy.removeValue(forKey: "animatesWindowMoves")
    let migrated = try JSONDecoder().decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(migrated == original)
    #expect(!migrated.animatesWindowMoves)
}

@Test func invalidAndConflictingBindingsAreRejected() {
    #expect(!Shortcut(modifiers: [], trigger: .mouse(button: 0)).isValid)
    #expect(!Shortcut(modifiers: .command, trigger: .mouse(button: -1)).isValid)
    #expect(!Shortcut(modifiers: .command, trigger: .key(code: 55, label: "Command")).isValid)
    #expect(!Shortcut(modifiers: ShortcutModifiers(rawValue: 128), trigger: .mouse(button: 0)).isValid)
    let a = Shortcut(modifiers: .command, trigger: .key(code: 0, label: "A"))
    let b = Shortcut(modifiers: .command, trigger: .key(code: 0, label: "a"))
    #expect(a.conflicts(with: b))
    #expect(!AppPreferences(left: a, right: b).isValid)
}

@Test func matchedMousePressSuppressesDragAndReleaseAfterModifiersChange() {
    var router = InputRouter()
    let preferences = AppPreferences()
    #expect(router.route(identity: .mouse(0), phase: .down, modifiers: [.control, .command, .shift], preferences: preferences)
            == InputDecision(suppress: true, direction: .left))
    #expect(router.route(identity: .mouse(0), phase: .drag, modifiers: [], preferences: preferences).suppress)
    #expect(router.route(identity: .mouse(0), phase: .up, modifiers: [], preferences: preferences).suppress)
    #expect(!router.route(identity: .mouse(0), phase: .down, modifiers: [], preferences: preferences).suppress)
    #expect(!router.route(identity: .mouse(0), phase: .up, modifiers: [], preferences: preferences).suppress)
}

@Test func ordinaryInputAndRecordingPassThrough() {
    var router = InputRouter()
    let preferences = AppPreferences()
    #expect(!router.route(identity: .mouse(1), phase: .down, modifiers: [], preferences: preferences).suppress)
    #expect(!router.route(identity: .mouse(0), phase: .down, modifiers: [.control, .command, .shift],
                         preferences: preferences, isRecording: true).suppress)
    #expect(!router.route(identity: .key(0), phase: .down, modifiers: .command, preferences: preferences).suppress)
}

@Test func keyboardAutoRepeatDoesNotCycleThroughMultipleScreens() {
    var router = InputRouter()
    var preferences = AppPreferences()
    preferences.left = Shortcut(modifiers: [.control, .option], trigger: .key(code: 123, label: "←"))
    #expect(router.route(identity: .key(123), phase: .down, modifiers: [.control, .option], preferences: preferences).direction == .left)
    let repeated = router.route(identity: .key(123), phase: .down, modifiers: [.control, .option], preferences: preferences, isRepeat: true)
    #expect(repeated.suppress && repeated.direction == nil)
    #expect(router.route(identity: .key(123), phase: .up, modifiers: [], preferences: preferences).suppress)
    #expect(router.route(identity: .key(123), phase: .down, modifiers: [.control, .option], preferences: preferences).direction == .left)
}

@Test func pausingDoesNotLeakPreviouslyCapturedMouseRelease() {
    var router = InputRouter()
    var preferences = AppPreferences()
    _ = router.route(identity: .mouse(0), phase: .down, modifiers: [.control, .command, .shift], preferences: preferences)
    preferences.isEnabled = false
    #expect(router.route(identity: .mouse(0), phase: .up, modifiers: [], preferences: preferences).suppress)
    #expect(!router.route(identity: .mouse(0), phase: .down, modifiers: [.control, .command, .shift], preferences: preferences).suppress)
}

@Test func systemForceQuitIsAlwaysAvailable() {
    var router = InputRouter()
    var preferences = AppPreferences()
    preferences.left = Shortcut(modifiers: [.option, .command], trigger: .key(code: 53, label: "Esc"))
    #expect(!preferences.isValid)
    #expect(!router.route(identity: .key(53), phase: .down, modifiers: [.option, .command], preferences: preferences).suppress)
    #expect(!router.route(identity: .key(53), phase: .down, modifiers: [.control, .shift, .option, .command], preferences: preferences).suppress)
}

import CoreGraphics
import Foundation
import QuickShiftCore
import Testing
@testable import QuickShiftDisplay

private func parityMonitor() -> GlobalShortcutMonitor {
    GlobalShortcutMonitor(statusURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("QuickShift-parity-\(UUID().uuidString).state"))
}

private func flags(_ modifiers: ShortcutModifiers) -> CGEventFlags {
    var flags: CGEventFlags = []
    if modifiers.contains(.control) { flags.insert(.maskControl) }
    if modifiers.contains(.option) { flags.insert(.maskAlternate) }
    if modifiers.contains(.shift) { flags.insert(.maskShift) }
    if modifiers.contains(.command) { flags.insert(.maskCommand) }
    return flags
}

@Test func nativeMouseRouterAgreesWithReferenceAcrossModifierAndBindingChanges() {
    let monitor = parityMonitor()
    var reference = InputRouter()
    var preferences = AppPreferences()
    let requested: ShortcutModifiers = [.control, .command, .shift]

    func check(_ button: Int, _ phase: InputPhase, _ modifiers: ShortcutModifiers) {
        let type: CGEventType
        switch (button, phase) {
        case (0, .down): type = .leftMouseDown
        case (0, .up): type = .leftMouseUp
        case (0, .drag): type = .leftMouseDragged
        case (1, .down): type = .rightMouseDown
        case (1, .up): type = .rightMouseUp
        case (1, .drag): type = .rightMouseDragged
        case (_, .down): type = .otherMouseDown
        case (_, .up): type = .otherMouseUp
        case (_, .drag): type = .otherMouseDragged
        }
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left)!
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        event.flags = flags(modifiers).union([.maskAlphaShift, .maskSecondaryFn])
        let expected = reference.route(identity: .mouse(button), phase: phase, modifiers: modifiers, preferences: preferences)
        #expect(monitor.handle(type: type, event: event) == expected.suppress)
    }
    check(0, .down, [])
    check(0, .up, requested)
    check(0, .down, requested.union(.option))
    check(0, .up, [])
    check(0, .down, requested)
    check(0, .drag, [])
    preferences.left = Shortcut(modifiers: .option, trigger: .mouse(button: 4))
    monitor.preferences = preferences
    check(0, .up, [])
    check(0, .down, requested)
    check(0, .up, [])
    check(4, .down, .option)
    check(4, .drag, [])
    check(4, .up, [])
    check(1, .down, requested)
    preferences.isEnabled = false
    monitor.preferences = preferences
    check(1, .up, [])
    check(1, .down, requested)
}

@Test func nativeKeyboardRouterAgreesWithReferenceIncludingRepeatAndForceQuit() {
    let monitor = parityMonitor()
    var reference = InputRouter()
    var preferences = AppPreferences()
    preferences.left = Shortcut(modifiers: [.control, .option], trigger: .key(code: 123, label: "←"))
    monitor.preferences = preferences

    func check(_ code: UInt16, _ phase: InputPhase, _ modifiers: ShortcutModifiers, repeated: Bool = false) {
        let type: CGEventType = phase == .down ? .keyDown : .keyUp
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: phase == .down)!
        event.flags = flags(modifiers).union([.maskAlphaShift, .maskNumericPad])
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
        let expected = reference.route(identity: .key(code), phase: phase, modifiers: modifiers,
                                       preferences: preferences, isRepeat: repeated)
        #expect(monitor.handle(type: type, event: event) == expected.suppress)
    }
    check(123, .down, [.control, .option])
    check(123, .down, [], repeated: true)
    check(123, .up, [])
    check(123, .down, [], repeated: true)
    check(123, .up, [])
    check(123, .down, [.control, .option, .command])
    check(123, .up, [])
    // Even a deliberately invalid caller configuration cannot take over Force Quit.
    preferences.left = Shortcut(modifiers: [.command, .option], trigger: .key(code: 53, label: "Esc"))
    monitor.preferences = preferences
    check(53, .down, [.command, .option])
    check(53, .up, [.control, .command, .option, .shift])
}

@Test func nativeCanonicalMouseButtonsDoNotDependOnAuxiliaryButtonField() {
    let monitor = parityMonitor()
    let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
    down.setIntegerValueField(.mouseEventButtonNumber, value: 0)
    down.flags = [.maskControl, .maskCommand, .maskShift]
    #expect(monitor.handle(type: .rightMouseDown, event: down))
    let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: .zero, mouseButton: .left)!
    #expect(monitor.handle(type: .rightMouseUp, event: up))
}

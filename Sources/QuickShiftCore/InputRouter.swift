import Foundation

public enum InputPhase: Sendable { case down, up, drag }

public enum InputIdentity: Hashable, Sendable {
    case mouse(Int)
    case key(UInt16)
}

public struct InputDecision: Equatable, Sendable {
    public var suppress: Bool
    public var direction: MoveDirection?

    public init(suppress: Bool, direction: MoveDirection? = nil) {
        self.suppress = suppress
        self.direction = direction
    }
}

/// A matched press owns its entire down/drag/up sequence, even if modifiers are released first.
public struct InputRouter: Sendable {
    private var captured = Set<InputIdentity>()

    public init() {}

    public mutating func route(
        identity: InputIdentity, phase: InputPhase, modifiers: ShortcutModifiers,
        preferences: AppPreferences, isRecording: Bool = false, isRepeat: Bool = false
    ) -> InputDecision {
        // Always preserve the system Force Quit chord, including with extra modifiers.
        if identity == .key(53), modifiers.contains([.option, .command]) {
            return InputDecision(suppress: false, direction: nil)
        }
        if captured.contains(identity) {
            if phase == .up { captured.remove(identity) }
            return InputDecision(suppress: true, direction: nil)
        }
        guard phase == .down, !isRecording, !isRepeat else {
            return InputDecision(suppress: false, direction: nil)
        }
        let trigger: ShortcutTrigger
        switch identity {
        case let .mouse(button): trigger = .mouse(button: button)
        case let .key(code): trigger = .key(code: code, label: "")
        }
        guard let direction = preferences.direction(modifiers: modifiers, trigger: trigger) else {
            return InputDecision(suppress: false, direction: nil)
        }
        captured.insert(identity)
        return InputDecision(suppress: true, direction: direction)
    }

    public mutating func reset() { captured.removeAll() }
}

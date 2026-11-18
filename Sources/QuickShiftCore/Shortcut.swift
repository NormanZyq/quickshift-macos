import Foundation

public enum MoveDirection: String, Codable, Sendable, CaseIterable {
    case left, right

    public var title: String { self == .left ? "向左移动" : "向右移动" }
}

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = Self(rawValue: 1 << 0)
    public static let option = Self(rawValue: 1 << 1)
    public static let shift = Self(rawValue: 1 << 2)
    public static let command = Self(rawValue: 1 << 3)
    public static let supported: Self = [.control, .option, .shift, .command]

    public var symbols: String {
        [(Self.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { contains($0.0) }.map(\.1).joined()
    }
}

public enum ShortcutTrigger: Codable, Equatable, Sendable {
    case mouse(button: Int)
    case key(code: UInt16, label: String)

    public var title: String {
        switch self {
        case .mouse(button: 0): "鼠标左键"
        case .mouse(button: 1): "鼠标右键"
        case .mouse(button: 2): "鼠标中键"
        case let .mouse(button): "鼠标键 \(button + 1)"
        case let .key(_, label): label
        }
    }

    /// Labels are presentation only; key codes identify physical keys.
    public func matches(_ other: Self) -> Bool {
        switch (self, other) {
        case let (.mouse(a), .mouse(b)): a == b
        case let (.key(a, _), .key(b, _)): a == b
        default: false
        }
    }
}

public struct Shortcut: Codable, Equatable, Sendable {
    public var modifiers: ShortcutModifiers
    public var trigger: ShortcutTrigger

    public init(modifiers: ShortcutModifiers, trigger: ShortcutTrigger) {
        self.modifiers = modifiers
        self.trigger = trigger
    }

    public var title: String { "\(modifiers.symbols)  \(trigger.title)" }

    public var isValid: Bool {
        guard !modifiers.isEmpty, modifiers.isSubset(of: .supported) else { return false }
        switch trigger {
        case let .mouse(button): return (0...31).contains(button)
        case let .key(code, label):
            if code == 53 && modifiers.contains([.option, .command]) { return false }
            // Modifier keys and Fn are not standalone triggers.
            return code <= 127 && ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(code)
                && !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public func matches(modifiers: ShortcutModifiers, trigger: ShortcutTrigger) -> Bool {
        self.modifiers == modifiers && self.trigger.matches(trigger)
    }

    public func conflicts(with other: Self) -> Bool {
        modifiers == other.modifiers && trigger.matches(other.trigger)
    }
}

public struct AppPreferences: Codable, Equatable, Sendable {
    public var left: Shortcut
    public var right: Shortcut
    public var wrapsDisplays: Bool
    public var isEnabled: Bool
    public var animatesWindowMoves: Bool

    public init(
        left: Shortcut = Shortcut(modifiers: [.control, .command, .shift], trigger: .mouse(button: 0)),
        right: Shortcut = Shortcut(modifiers: [.control, .command, .shift], trigger: .mouse(button: 1)),
        wrapsDisplays: Bool = true,
        isEnabled: Bool = true,
        animatesWindowMoves: Bool = false
    ) {
        self.left = left
        self.right = right
        self.wrapsDisplays = wrapsDisplays
        self.isEnabled = isEnabled
        self.animatesWindowMoves = animatesWindowMoves
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(left: try values.decode(Shortcut.self, forKey: .left),
                  right: try values.decode(Shortcut.self, forKey: .right),
                  wrapsDisplays: try values.decode(Bool.self, forKey: .wrapsDisplays),
                  isEnabled: try values.decode(Bool.self, forKey: .isEnabled),
                  animatesWindowMoves: try values.decodeIfPresent(Bool.self, forKey: .animatesWindowMoves) ?? false)
    }

    public var isValid: Bool { left.isValid && right.isValid && !left.conflicts(with: right) }

    public func shortcut(for direction: MoveDirection) -> Shortcut {
        direction == .left ? left : right
    }

    public mutating func set(_ shortcut: Shortcut, for direction: MoveDirection) {
        if direction == .left { left = shortcut } else { right = shortcut }
    }

    public func direction(modifiers: ShortcutModifiers, trigger: ShortcutTrigger) -> MoveDirection? {
        guard isEnabled else { return nil }
        return MoveDirection.allCases.first { shortcut(for: $0).matches(modifiers: modifiers, trigger: trigger) }
    }
}

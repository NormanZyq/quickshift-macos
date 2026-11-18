import AppKit
import QuickShiftCore

@MainActor
final class ShortcutRecorderController: NSWindowController {
    private let direction: MoveDirection
    private let otherShortcut: Shortcut
    private let onFinish: (Shortcut?) -> Void
    private var candidate: Shortcut?
    private var finished = false
    private let captureView = ShortcutCaptureView(frame: .zero)
    private let preview = NSTextField(wrappingLabelWithString: "至少按住一个修饰键：⌃ Control、⌥ Option、⇧ Shift 或 ⌘ Command。")
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)

    init(direction: MoveDirection, otherShortcut: Shortcut, onFinish: @escaping (Shortcut?) -> Void) {
        self.direction = direction
        self.otherShortcut = otherShortcut
        self.onFinish = onFinish
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 278),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        panel.title = "录制\(direction.title)快捷键"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        buildContent(panel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        window.makeFirstResponder(captureView)
    }

    func cancel() { finish(nil) }

    private func buildContent(_ panel: NSPanel) {
        let title = NSTextField(labelWithString: "按下你想使用的组合键")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: "键盘组合键可直接按下；鼠标组合键请在下方区域点击。")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        captureView.translatesAutoresizingMaskIntoConstraints = false
        captureView.heightAnchor.constraint(equalToConstant: 80).isActive = true
        captureView.onShortcut = { [weak self] shortcut in self?.capture(shortcut) }
        captureView.onCancel = { [weak self] in self?.cancel() }
        preview.font = .systemFont(ofSize: 12)
        preview.textColor = .secondaryLabelColor
        preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.bezelStyle = .rounded
        saveButton.isEnabled = false
        let spacer = NSView()
        let buttons = NSStackView(views: [spacer, cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [title, hint, captureView, preview, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
                captureView.widthAnchor.constraint(equalTo: stack.widthAnchor),
                preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
                buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
        }
    }

    private func capture(_ shortcut: Shortcut) {
        guard shortcut.isValid else {
            candidate = nil
            saveButton.isEnabled = false
            captureView.recordedTitle = nil
            if case .key(code: 53, label: _) = shortcut.trigger, shortcut.modifiers.contains([.option, .command]) {
                preview.stringValue = "⌘⌥Esc 保留给系统强制退出，请使用其他组合键。"
            } else {
                preview.stringValue = "请按住至少一个修饰键，再按键或点击鼠标。"
            }
            preview.textColor = .systemOrange
            return
        }
        guard !shortcut.conflicts(with: otherShortcut) else {
            candidate = nil
            saveButton.isEnabled = false
            captureView.recordedTitle = nil
            preview.stringValue = "这个组合键已用于另一个方向，请换一个。"
            preview.textColor = .systemOrange
            return
        }
        candidate = shortcut
        saveButton.isEnabled = true
        preview.stringValue = "将使用：\(shortcut.title)"
        preview.textColor = .labelColor
        captureView.recordedTitle = shortcut.title
    }

    private func finish(_ shortcut: Shortcut?) {
        guard !finished else { return }
        finished = true
        if let window {
            window.sheetParent?.endSheet(window)
            window.orderOut(nil)
        }
        onFinish(shortcut)
    }

    @objc private func cancelClicked() { cancel() }
    @objc private func saveClicked() { if let candidate { finish(candidate) } }
}

@MainActor
private final class ShortcutCaptureView: NSView {
    var onShortcut: ((Shortcut) -> Void)?
    var onCancel: (() -> Void)?
    var recordedTitle: String? {
        didSet {
            needsDisplay = true
            setAccessibilityValue(recordedTitle ?? "等待组合键")
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }
    private var modifiers: ShortcutModifiers = [] { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("快捷键录制区域")
        setAccessibilityValue("等待组合键")
        setAccessibilityHelp("按住修饰键，按下键盘按键或在此点击鼠标。按 Esc 取消。")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        return true
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.07).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 1.5
        path.stroke()
        let title = recordedTitle ?? (modifiers.isEmpty ? "在此点击鼠标，或按下键盘组合键" : "\(modifiers.symbols)  …")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.labelColor,
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func flagsChanged(with event: NSEvent) { modifiers = ShortcutModifiers(event.modifierFlags) }
    override func mouseDown(with event: NSEvent) { captureMouse(event) }
    override func rightMouseDown(with event: NSEvent) { captureMouse(event) }
    override func otherMouseDown(with event: NSEvent) { captureMouse(event) }
    override func keyDown(with event: NSEvent) { captureKey(event) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        captureKey(event)
        return true
    }

    private func captureMouse(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        onShortcut?(Shortcut(modifiers: ShortcutModifiers(event.modifierFlags), trigger: .mouse(button: event.buttonNumber)))
    }

    private func captureKey(_ event: NSEvent) {
        let modifiers = ShortcutModifiers(event.modifierFlags)
        if event.keyCode == 53 && modifiers.isEmpty { onCancel?(); return }
        guard !event.isARepeat else { return }
        onShortcut?(Shortcut(
            modifiers: modifiers,
            trigger: .key(code: event.keyCode, label: Self.keyLabel(event))
        ))
    }

    private static func keyLabel(_ event: NSEvent) -> String {
        let names: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
            64: "F17", 65: "小键盘 .", 67: "小键盘 *", 69: "小键盘 +", 71: "Clear",
            75: "小键盘 /", 76: "Enter", 78: "小键盘 −", 81: "小键盘 =",
            82: "小键盘 0", 83: "小键盘 1", 84: "小键盘 2", 85: "小键盘 3",
            86: "小键盘 4", 87: "小键盘 5", 88: "小键盘 6", 89: "小键盘 7",
            91: "小键盘 8", 92: "小键盘 9", 96: "F5", 97: "F6", 98: "F7",
            99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16",
            107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help",
            115: "Home", 116: "Page Up", 117: "⌦", 118: "F4", 119: "End",
            120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        if let name = names[event.keyCode] { return name }
        let characters = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "")
            .trimmingCharacters(in: .controlCharacters)
        return characters.isEmpty ? "Key \(event.keyCode)" : characters.uppercased()
    }
}

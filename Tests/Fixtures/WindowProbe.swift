import AppKit

struct ProbeVisit: Codable {
    let screenID: UInt32
    let screenName: String
    let order: Int
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let inputEvents: Int
}

struct ProbeState: Codable {
    let processID: Int32
    let history: [ProbeVisit]
    let inputEvents: Int
}

// A disposable native window for manual, cross-process end-to-end testing.
@MainActor
final class ProbeDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let status = NSTextField(wrappingLabelWithString: "")
    private let input = InputProbeView(frame: .zero)
    private var inputEvents = 0
    private var history: [ProbeVisit] = []
    private let traceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/probe-state.json")

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "QuickShift 移屏测试"
        window.minSize = NSSize(width: 320, height: 240)
        window.delegate = self
        window.isReleasedWhenClosed = false
        let heading = NSTextField(labelWithString: "QuickShift 独立测试窗口")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        status.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        input.onInput = { [weak self] in
            guard let self else { return }
            inputEvents += 1
            refresh()
        }
        let fill = NSButton(title: "铺满当前屏幕", target: self, action: #selector(fillScreen))
        let restore = NSButton(title: "恢复普通尺寸", target: self, action: #selector(restoreSize))
        let buttons = NSStackView(views: [fill, restore])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [heading, status, input, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            input.widthAnchor.constraint(equalTo: stack.widthAnchor),
            input.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
        if let area = NSScreen.screens.first?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(input)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    func windowDidMove(_ notification: Notification) { refresh() }
    func windowDidResize(_ notification: Notification) { refresh() }
    func windowDidChangeScreen(_ notification: Notification) { refresh() }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    private func refresh() {
        guard let window else { return }
        let frame = window.frame
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        guard let screen = window.screen else { return }
        let name = screen.localizedName
        let screenID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let orderedScreens = NSScreen.screens.sorted {
            if $0.frame.midX != $1.frame.midX { return $0.frame.midX < $1.frame.midX }
            return $0.frame.midY > $1.frame.midY
        }
        let order = (orderedScreens.firstIndex(of: screen) ?? 0) + 1
        let visit = ProbeVisit(screenID: screenID, screenName: name, order: order,
                               x: Int(frame.minX), y: Int(primaryTop - frame.maxY),
                               width: Int(frame.width), height: Int(frame.height), inputEvents: inputEvents)
        if history.last?.screenID == screenID {
            history[history.count - 1] = visit
        } else {
            history.append(visit)
        }
        let path = history.suffix(12).map { String($0.order) }.joined(separator: " → ")
        window.title = "移屏测试 · \(name)"
        status.stringValue = "屏幕：\(name)\n位置（AX）：\(Int(frame.minX)), \(Int(primaryTop - frame.maxY))\n窗口大小：\(Int(frame.width)) × \(Int(frame.height))\n收到的输入事件：\(inputEvents)\n路径：\(path)"
        if let data = try? JSONEncoder().encode(ProbeState(processID: ProcessInfo.processInfo.processIdentifier,
                                                         history: history, inputEvents: inputEvents)) {
            try? data.write(to: traceURL, options: .atomic)
        }
    }

    @objc private func fillScreen() {
        if let area = window.screen?.visibleFrame { window.setFrame(area, display: true) }
    }

    @objc private func restoreSize() {
        let origin = window.frame.origin
        inputEvents = 0
        history.removeAll()
        window.setFrame(NSRect(origin: origin, size: NSSize(width: 720, height: 440)), display: true)
        refresh()
    }
}

@MainActor
final class InputProbeView: NSView {
    var onInput: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("组合键测试区域")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        let title = "在此按组合键；成功拦截时，输入事件数保持不变。"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]
        let size = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: max(8, (bounds.width - size.width) / 2), y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) { onInput?() }
    override func mouseUp(with event: NSEvent) { onInput?() }
    override func rightMouseDown(with event: NSEvent) { onInput?() }
    override func rightMouseUp(with event: NSEvent) { onInput?() }
    override func keyDown(with event: NSEvent) { onInput?() }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = ProbeDelegate()
app.delegate = delegate
withExtendedLifetime(delegate) { app.run() }

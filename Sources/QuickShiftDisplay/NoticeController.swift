import AppKit

@MainActor
final class NoticeController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String) {
        dismissTask?.cancel()
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 54),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .statusBar
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let background = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
            background.material = .popover
            background.state = .active
            background.wantsLayer = true
            background.layer?.cornerRadius = 12
            background.layer?.masksToBounds = true
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
                label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            ])
            panel.contentView = background
            self.panel = panel
        }
        guard let panel else { return }
        (panel.contentView?.subviews.first as? NSTextField)?.stringValue = message
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2, y: screen.visibleFrame.maxY - 90))
        }
        panel.orderFrontRegardless()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }
}

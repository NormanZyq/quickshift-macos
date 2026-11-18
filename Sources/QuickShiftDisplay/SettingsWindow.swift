import AppKit
import QuickShiftCore

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let store: SettingsStore
    var onRequestAccessibility: (() -> Void)?
    var onRequestInputMonitoring: (() -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    var onRestartMonitoring: (() -> Void)?
    var onSetLoginItemEnabled: ((Bool) -> Void)?
    var onRequestLoginItemSettings: (() -> Void)?
    private var recorder: ShortcutRecorderController?
    private let leftButton = NSButton()
    private let rightButton = NSButton()
    private let enabledCheckbox = NSButton(checkboxWithTitle: "启用全局快捷键", target: nil, action: nil)
    private let wrapCheckbox = NSButton(checkboxWithTitle: "循环切换显示器", target: nil, action: nil)
    private let animationCheckbox = NSButton(checkboxWithTitle: "移屏动画", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "登录时启动", target: nil, action: nil)
    private let loginDetail = NSTextField(wrappingLabelWithString: "")
    private let loginSettingsButton = NSButton(title: "打开登录项设置…", target: nil, action: nil)
    private let displayLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let permissionDetail = NSTextField(wrappingLabelWithString: "")
    private let permissionButton = NSButton(title: "打开辅助功能设置…", target: nil, action: nil)
    private let inputButton = NSButton(title: "检查输入监控…", target: nil, action: nil)
    private let restartButton = NSButton(title: "重新启动监听", target: nil, action: nil)

    init(store: SettingsStore, testOnly: Bool = false) {
        self.store = store
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let availableHeight = NSScreen.main.map { NSWindow.contentRect(forFrameRect: $0.visibleFrame, styleMask: style).height } ?? 820
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: min(820, availableHeight)),
            styleMask: style, backing: .buffered, defer: false
        )
        window.title = testOnly ? "QuickShift 设置 · 隔离测试" : "QuickShift 设置"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: min(360, availableHeight))
        window.center()
        window.setFrameAutosaveName("QuickShiftSettings")
        super.init(window: window)
        window.delegate = self
        buildContent(window)
        refreshPreferences()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func refreshPreferences() {
        let preferences = store.preferences
        leftButton.title = preferences.left.title
        rightButton.title = preferences.right.title
        enabledCheckbox.state = preferences.isEnabled ? .on : .off
        wrapCheckbox.state = preferences.wrapsDisplays ? .on : .off
        animationCheckbox.state = preferences.animatesWindowMoves ? .on : .off
    }

    func refreshStatus(trusted: Bool, listening: Bool, displays: [DisplayInfo], safelySuspended: Bool = false,
                       testOnly: Bool = false, startupSuspension: String? = nil) {
        if !store.preferences.isEnabled {
            statusLabel.stringValue = "●  快捷键已暂停"
            statusLabel.textColor = .secondaryLabelColor
            permissionDetail.stringValue = trusted
                ? (testOnly ? "当前监听关闭。启用后仅处理 QuickShiftProbe 测试窗口的输入。" : "当前没有安装全局输入监听。开启下方“启用全局快捷键”后即可使用。")
                : (testOnly ? "当前监听关闭。授权并启用后，仅处理 QuickShiftProbe 测试窗口的输入。" : "当前没有安装全局输入监听。使用前请先授权辅助功能，再开启下方快捷键开关。")
        } else if !trusted {
            statusLabel.stringValue = "●  需要辅助功能权限"
            statusLabel.textColor = .systemOrange
            permissionDetail.stringValue = "请在辅助功能中开启 QuickShift。若更新后开关已开启，仍提示需要权限，可移除旧的 QuickShift 条目，再添加当前安装的应用。"
        } else if safelySuspended {
            statusLabel.stringValue = "●  输入监听已保护性暂停"
            statusLabel.textColor = .systemOrange
            permissionDetail.stringValue = "系统已关闭输入监听以恢复正常输入。需要时可手动重新启动监听。"
        } else if let startupSuspension {
            statusLabel.stringValue = "●  本次监听已暂停"
            statusLabel.textColor = .systemOrange
            permissionDetail.stringValue = startupSuspension
        } else if !listening {
            statusLabel.stringValue = "●  辅助功能已授权，输入监听未启动"
            statusLabel.textColor = .systemOrange
            permissionDetail.stringValue = "请检查输入监控权限；若刚刚授权，可退出并重新打开 QuickShift。"
        } else {
            statusLabel.stringValue = store.preferences.isEnabled ? "●  已就绪" : "●  快捷键已暂停"
            statusLabel.textColor = store.preferences.isEnabled ? .systemGreen : .secondaryLabelColor
            permissionDetail.stringValue = testOnly ? "隔离测试模式：只处理 QuickShiftProbe 测试窗口的输入。"
                : "辅助功能已授权。QuickShift 在菜单栏运行，关闭此窗口后仍可使用。"
        }
        permissionButton.title = trusted ? "查看辅助功能设置…" : "打开辅助功能设置…"
        inputButton.isHidden = !trusted || listening || safelySuspended || startupSuspension != nil || !store.preferences.isEnabled
        restartButton.isHidden = !trusted || listening || !store.preferences.isEnabled
        let names = displays.enumerated().map { "\($0.offset + 1). \($0.element.name)" }.joined(separator: "   →   ")
        displayLabel.stringValue = displays.count > 1 ? names : "\(names)\n连接另一台显示器后即可移屏。"
    }

    func windowWillClose(_ notification: Notification) {
        recorder?.cancel()
        onClose?()
    }

    func refreshLoginItemStatus(_ status: LoginItemStatus, errorMessage: String?) {
        loginCheckbox.state = status.isRequested ? .on : .off
        loginDetail.stringValue = errorMessage ?? status.explanation
        loginDetail.textColor = errorMessage != nil || status.needsSystemSettings ? .systemOrange : .secondaryLabelColor
        loginSettingsButton.isHidden = !status.needsSystemSettings
    }

    private func buildContent(_ window: NSWindow) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        window.contentView = scroll
        let content = SettingsDocumentView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            content.topAnchor.constraint(equalTo: clip.topAnchor),
        ])
        let icon = NSImageView(image: NSImage(systemSymbolName: "display.2", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 36, weight: .medium)
        icon.widthAnchor.constraint(equalToConstant: 50).isActive = true
        let appTitle = label("QuickShift", size: 24, weight: .bold)
        let subtitle = label("让当前窗口，在屏幕之间轻松移动。", size: 13, secondary: true)
        let titleStack = vertical([appTitle, subtitle], spacing: 4)
        let header = NSStackView(views: [icon, titleStack, NSView()])
        header.orientation = .horizontal
        header.spacing = 14

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        permissionDetail.font = .systemFont(ofSize: 12)
        permissionDetail.textColor = .secondaryLabelColor
        permissionButton.target = self
        permissionButton.action = #selector(requestAccessibility)
        permissionButton.bezelStyle = .rounded
        inputButton.target = self
        inputButton.action = #selector(requestInput)
        inputButton.bezelStyle = .rounded
        restartButton.target = self
        restartButton.action = #selector(restartMonitoring)
        restartButton.bezelStyle = .rounded
        let permissionButtons = NSStackView(views: [permissionButton, inputButton, restartButton, NSView()])
        permissionButtons.orientation = .horizontal
        permissionButtons.spacing = 8
        let permissionGroup = card([statusLabel, permissionDetail, permissionButtons])

        let shortcutsTitle = label("快捷键", size: 14, weight: .semibold)
        configureShortcutButton(leftButton, direction: .left)
        configureShortcutButton(rightButton, direction: .right)
        let shortcutsGroup = card([
            shortcutsTitle,
            shortcutRow(title: "←  向左移动", button: leftButton),
            shortcutRow(title: "→  向右移动", button: rightButton),
            wrappingLabel("点击快捷键可重新录制，支持修饰键 + 鼠标按钮或键盘按键。"),
        ])

        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(toggleEnabled)
        wrapCheckbox.target = self
        wrapCheckbox.action = #selector(toggleWrap)
        animationCheckbox.target = self
        animationCheckbox.action = #selector(toggleAnimation)
        animationCheckbox.toolTip = "让窗口平滑移到目标显示器。系统开启“减少动态效果”时会即时移屏。"
        let behaviorGroup = card([
            enabledCheckbox, wrapCheckbox,
            wrappingLabel("开启循环：最左侧再向左会移到最右侧；关闭后在屏幕边缘停止。"),
            animationCheckbox,
        ])

        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLoginItem)
        loginDetail.font = .systemFont(ofSize: 12)
        loginDetail.preferredMaxLayoutWidth = 500
        loginDetail.textColor = .secondaryLabelColor
        loginSettingsButton.target = self
        loginSettingsButton.action = #selector(openLoginItemSettings)
        loginSettingsButton.bezelStyle = .rounded
        loginSettingsButton.isHidden = true
        let loginGroup = card([loginCheckbox, loginDetail, loginSettingsButton])

        displayLabel.font = .systemFont(ofSize: 12)
        displayLabel.textColor = .secondaryLabelColor
        let displaysGroup = vertical([
            label("显示器顺序", size: 13, weight: .semibold), displayLabel,
        ], spacing: 6)

        let resetButton = NSButton(title: "恢复默认快捷键", target: self, action: #selector(resetShortcuts))
        resetButton.bezelStyle = .rounded
        let versionString = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        let version = label("QuickShift \(versionString)", size: 11, secondary: true)
        let footer = NSStackView(views: [version, NSView(), resetButton])
        footer.orientation = .horizontal
        let stack = vertical([header, permissionGroup, shortcutsGroup, behaviorGroup, loginGroup, displaysGroup, footer], spacing: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        for view in [header, permissionGroup, shortcutsGroup, behaviorGroup, loginGroup, displaysGroup, footer] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        displayLabel.widthAnchor.constraint(equalTo: displaysGroup.widthAnchor).isActive = true
    }

    private func configureShortcutButton(_ button: NSButton, direction: MoveDirection) {
        button.bezelStyle = .rounded
        button.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        button.target = self
        button.action = #selector(recordShortcut(_:))
        button.tag = direction == .left ? 0 : 1
        button.toolTip = "点击重新录制\(direction.title)的快捷键"
        button.setAccessibilityLabel("\(direction.title)快捷键")
        button.widthAnchor.constraint(equalToConstant: 290).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
    }

    private func shortcutRow(title: String, button: NSButton) -> NSStackView {
        let row = NSStackView(views: [label(title, size: 13), NSView(), button])
        row.orientation = .horizontal
        row.spacing = 12
        return row
    }

    private func card(_ views: [NSView]) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.borderColor = .separatorColor
        box.borderWidth = 0.5
        box.cornerRadius = 10
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        let stack = vertical(views, spacing: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let content = box.contentView {
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            ])
            for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        }
        return box
    }

    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func label(_ title: String, size: CGFloat, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        return label
    }

    private func wrappingLabel(_ title: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    @objc private func toggleEnabled() { store.update { $0.isEnabled = enabledCheckbox.state == .on } }
    @objc private func toggleWrap() { store.update { $0.wrapsDisplays = wrapCheckbox.state == .on } }
    @objc private func toggleAnimation() { store.update { $0.animatesWindowMoves = animationCheckbox.state == .on } }
    @objc private func toggleLoginItem() { onSetLoginItemEnabled?(loginCheckbox.state == .on) }
    @objc private func openLoginItemSettings() { onRequestLoginItemSettings?() }
    @objc private func resetShortcuts() { store.resetShortcuts() }
    @objc private func requestAccessibility() { onRequestAccessibility?() }
    @objc private func requestInput() { onRequestInputMonitoring?() }
    @objc private func restartMonitoring() { onRestartMonitoring?() }

    @objc private func recordShortcut(_ sender: NSButton) {
        guard recorder == nil, let window else { return }
        let direction: MoveDirection = sender.tag == 0 ? .left : .right
        let other: MoveDirection = direction == .left ? .right : .left
        onRecordingChanged?(true)
        let recorder = ShortcutRecorderController(direction: direction, otherShortcut: store.preferences.shortcut(for: other)) { [weak self] shortcut in
            guard let self else { return }
            if let shortcut { store.update { $0.set(shortcut, for: direction) } }
            self.recorder = nil
            onRecordingChanged?(false)
        }
        self.recorder = recorder
        recorder.present(on: window)
    }
}

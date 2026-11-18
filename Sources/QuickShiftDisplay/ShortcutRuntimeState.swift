struct ShortcutRuntimeState {
    enum Suspension: Equatable {
        case requested, testMode, previousSafetyFault(UInt32)

        var explanation: String {
            switch self {
            case .requested: "本次启动已暂停监听，已保存的开关设置保持不变。点击“重新启动监听”恢复。"
            case .testMode: "测试模式已暂停监听。点击“重新启动监听”后，仅处理指定的测试窗口。"
            case .previousSafetyFault: "上次输入监听触发了保护性退出。已保留开关设置，点击“重新启动监听”恢复。"
            }
        }
    }

    private(set) var suspension: Suspension?

    init(forcePaused: Bool = false, testMode: Bool = false, previousSafetyFault: UInt32 = 0) {
        if previousSafetyFault != 0 { suspension = .previousSafetyFault(previousSafetyFault) }
        else if forcePaused { suspension = .requested }
        else if testMode { suspension = .testMode }
    }

    func shouldListen(userEnabled: Bool, trusted: Bool) -> Bool {
        userEnabled && trusted && suspension == nil
    }

    func shouldOpenSettings(hasLaunched: Bool, userEnabled: Bool, trusted: Bool) -> Bool {
        !hasLaunched || suspension != nil || (userEnabled && !trusted)
    }

    mutating func resume() { suspension = nil }
}

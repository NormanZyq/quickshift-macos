import AppKit
import InputSafety
import QuickShiftCore

/// Swift owns configuration and action delivery. The actual event callback is entirely C.
final class GlobalShortcutMonitor: @unchecked Sendable {
    typealias ShortcutHandler = @MainActor @Sendable (MoveDirection, pid_t?) -> Void

    private struct State {
        var preferences = AppPreferences()
        var isRecording = false
        var foregroundProcessID: pid_t?
        var onShortcut: ShortcutHandler?
        var owner: NativeOwner?
        var native: OpaquePointer? { owner?.pointer }
        var source: DispatchSourceRead?
        var attemptedStart = false
        var activity: NSObjectProtocol?
    }

    private let lock = NSLock()
    private var state = State()
    private let statusURL: URL
    private let targetProcessID: pid_t
    @MainActor var onUnexpectedStop: (() -> Void)?

    static var defaultStatusURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuickShift/input-safety.state")
    }

    static func lastStatus() -> QSDNativeStatus? {
        readStatus(at: defaultStatusURL)
    }

    static func readStatus(at url: URL) -> QSDNativeStatus? {
        var status = QSDNativeStatus()
        return url.path.withCString { QSDNativeInputReadStatus($0, &status) } ? status : nil
    }

    static func previousFaultURL(for statusURL: URL) -> URL {
        statusURL.appendingPathExtension("previous-fault")
    }

    @discardableResult
    static func preservePreviousFault(at statusURL: URL) -> Bool {
        guard let previous = readStatus(at: statusURL), previous.fault != 0 else { return false }
        do {
            let data = try Data(contentsOf: statusURL)
            try data.write(to: previousFaultURL(for: statusURL), options: .atomic)
            return true
        } catch { return false }
    }

    init(statusURL: URL = GlobalShortcutMonitor.defaultStatusURL, targetProcessID: pid_t = 0) {
        self.statusURL = statusURL
        self.targetProcessID = targetProcessID
    }

    deinit {
        if let native = state.native { QSDNativeInputStop(native) }
        if let activity = state.activity { ProcessInfo.processInfo.endActivity(activity) }
        state.source?.cancel()
    }

    var preferences: AppPreferences {
        get { lock.withLock { state.preferences } }
        set { lock.withLock { state.preferences = newValue; publishConfiguration() } }
    }

    var isRecording: Bool {
        get { lock.withLock { state.isRecording } }
        set { lock.withLock { state.isRecording = newValue; publishConfiguration() } }
    }

    var foregroundProcessID: pid_t? {
        get { lock.withLock { state.foregroundProcessID } }
        set {
            lock.withLock {
                state.foregroundProcessID = newValue
                if let native = state.native { QSDNativeInputSetForegroundPID(native, newValue ?? 0) }
            }
        }
    }

    var onShortcut: ShortcutHandler? {
        get { lock.withLock { state.onShortcut } }
        set { lock.withLock { state.onShortcut = newValue } }
    }

    @MainActor var isRunning: Bool {
        lock.withLock { state.native.map(QSDNativeInputIsRunning) ?? false }
    }

    @MainActor var isSafelySuspended: Bool {
        lock.withLock { state.native.map { QSDNativeInputFault($0) != 0 } ?? false }
    }

    @MainActor @discardableResult
    func start() -> Bool {
        lock.withLock {
            guard state.preferences.isEnabled, let native = ensureNative(), QSDNativeInputFault(native) == 0 else { return false }
            if state.attemptedStart { return QSDNativeInputIsRunning(native) }
            state.attemptedStart = true
            state.activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Keep the input safety deadline responsive"
            )
            let started = QSDNativeInputStart(native)
            if !started, let activity = state.activity {
                ProcessInfo.processInfo.endActivity(activity)
                state.activity = nil
            }
            return started
        }
    }

    @MainActor
    func stop() {
        lock.withLock {
            if let native = state.native { QSDNativeInputStop(native) }
            state.attemptedStart = false
            if let activity = state.activity { ProcessInfo.processInfo.endActivity(activity); state.activity = nil }
        }
    }

    @MainActor
    func resetSuspensionForUserRequest() {
        stop()
        lock.withLock {
            if let native = state.native { QSDNativeInputResetFault(native) }
            state.attemptedStart = false
        }
    }

    /// Tests pass in-memory events through the same C router; this never creates an event tap.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        lock.withLock {
            guard let native = ensureNative() else { return false }
            return QSDNativeInputRouteForTesting(native, type, event)
        }
    }

    private func ensureNative() -> OpaquePointer? {
        if let native = state.native { return native }
        do {
            try FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch { return nil }
        // Archive on a later startup, before resetting the shared state. The safety-exit
        // path itself still performs no file I/O and never waits on Swift or AppKit.
        Self.preservePreviousFault(at: statusURL)
        guard let native = statusURL.path.withCString({ QSDNativeInputCreate($0, targetProcessID) }) else { return nil }
        let owner = NativeOwner(pointer: native)
        state.owner = owner
        publishConfiguration()
        let source = DispatchSource.makeReadSource(fileDescriptor: QSDNativeInputSignalFD(native), queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.deliverActions() }
        }
        // The descriptor is closed only after libdispatch finishes cancelling its source.
        source.setCancelHandler { owner.destroy() }
        state.source = source
        source.resume()
        return native
    }

    @MainActor
    private func deliverActions() {
        guard let native = lock.withLock({ state.native }) else { return }
        QSDNativeInputDrainSignal(native)
        var action = QSDNativeAction()
        while QSDNativeInputReadAction(native, &action) {
            let callback = lock.withLock { state.onShortcut }
            callback?(action.direction == 0 ? .left : .right, action.foregroundPID > 0 ? action.foregroundPID : nil)
        }
        let endedActivity = lock.withLock { () -> NSObjectProtocol? in
            guard let activity = state.activity, !QSDNativeInputIsRunning(native) else { return nil }
            state.activity = nil
            return activity
        }
        if let endedActivity {
            ProcessInfo.processInfo.endActivity(endedActivity)
            onUnexpectedStop?()
        }
    }

    private func publishConfiguration() {
        guard let native = state.native else { return }
        QSDNativeInputConfigure(native, QSDNativeConfiguration(
            left: Self.nativeShortcut(state.preferences.left), right: Self.nativeShortcut(state.preferences.right),
            foregroundPID: state.foregroundProcessID ?? 0, enabled: state.preferences.isEnabled, recording: state.isRecording
        ))
    }

    private static func nativeShortcut(_ shortcut: Shortcut) -> QSDNativeShortcut {
        switch shortcut.trigger {
        case let .mouse(button):
            QSDNativeShortcut(code: UInt16(clamping: button), kind: 0, modifiers: shortcut.modifiers.rawValue)
        case let .key(code, _):
            QSDNativeShortcut(code: code, kind: 1, modifiers: shortcut.modifiers.rawValue)
        }
    }
}

private final class NativeOwner: @unchecked Sendable {
    let pointer: OpaquePointer
    private let lock = NSLock()
    private var destroyed = false

    init(pointer: OpaquePointer) { self.pointer = pointer }
    func destroy() {
        let shouldDestroy = lock.withLock {
            if destroyed { return false }
            destroyed = true
            return true
        }
        if shouldDestroy { QSDNativeInputDestroy(pointer) }
    }
    deinit { destroy() }
}

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import QuickShiftCore

struct MoveReceipt: Sendable { let displayName: String }

enum MoveFailure: LocalizedError, Sendable {
    case singleDisplay, edge(MoveDirection), noWindow, fullScreen, notMovable, readFailed, moveFailed, busy

    var errorDescription: String? {
        switch self {
        case .singleDisplay: "连接另一台显示器后即可移屏"
        case .edge(let direction): direction == .left ? "已经是最左侧屏幕" : "已经是最右侧屏幕"
        case .noWindow: "当前应用没有可移动的窗口"
        case .fullScreen: "请先退出系统全屏，再移动窗口"
        case .notMovable: "这个窗口不支持通过辅助功能移动"
        case .readFailed: "无法读取窗口，请检查辅助功能权限"
        case .moveFailed: "应用未响应移屏操作，请重试"
        case .busy: "移屏请求已过期或应用正忙，请重试"
        }
    }
}

/// AX IPC can block on another app. Keep it off the event tap's main run loop.
final class WindowMover: Sendable {
    typealias Completion = @MainActor @Sendable (Result<MoveReceipt, MoveFailure>) -> Void
    typealias OwnMove = @MainActor @Sendable (NSWindow?, MoveDirection, [DisplayInfo], Bool, Bool, @escaping Completion) -> Void
    typealias ExternalMove = @Sendable (pid_t, MoveDirection, [DisplayInfo], Bool, Bool) -> Result<MoveReceipt, MoveFailure>
    private let queue = DispatchQueue(label: "local.quickshiftdisplay.window-mover", qos: .userInteractive)
    private let ownMove: OwnMove
    private let externalMove: ExternalMove
    private static let responseTimeoutMilliseconds = 600
    private static let maximumPendingMoves = 4
    @MainActor private var pendingExternalMoves = 0
    @MainActor private var localMoves: [@MainActor () -> Void] = []

    init(ownMove: OwnMove? = nil, externalMove: ExternalMove? = nil) {
        self.ownMove = ownMove ?? LocalWindowMover.move
        self.externalMove = externalMove ?? { processID, direction, displays, wraps, animate in
            Self.performMove(processID: processID, direction: direction, displays: displays, wraps: wraps, animate: animate)
        }
    }

    @MainActor
    func move(
        processID: pid_t, direction: MoveDirection, displays: [DisplayInfo], wraps: Bool, animate: Bool = false,
        completion: @escaping Completion
    ) {
        let deadline = DispatchTime.now() + .milliseconds(Self.responseTimeoutMilliseconds)
        // Capture the local window now. A second shortcut needs the first move's
        // settled geometry, even if the user presses it mid-animation.
        if processID == ProcessInfo.processInfo.processIdentifier {
            guard localMoves.count < Self.maximumPendingMoves else { completion(.failure(.busy)); return }
            let window = NSApp?.keyWindow ?? NSApp?.mainWindow
            let first = localMoves.isEmpty
            let finish: Completion = { result in
                completion(result)
                self.localMoves.removeFirst()
                self.localMoves.first?()
            }
            localMoves.append { [self] in
                guard DispatchTime.now() < deadline else { finish(.failure(.busy)); return }
                ownMove(window, direction, displays, wraps, animate && first, finish)
            }
            if first { localMoves.first?() }
            return
        }
        // A stalled AX client must not accumulate moves that replay on a later window.
        guard pendingExternalMoves < Self.maximumPendingMoves else { completion(.failure(.busy)); return }
        let animateThisMove = animate && pendingExternalMoves == 0
        pendingExternalMoves += 1
        queue.async {
            let result: Result<MoveReceipt, MoveFailure> = DispatchTime.now() < deadline
                ? self.externalMove(processID, direction, displays, wraps, animateThisMove) : .failure(.busy)
            DispatchQueue.main.async {
                self.pendingExternalMoves -= 1
                completion(result)
            }
        }
    }

    private static func performMove(
        processID: pid_t, direction: MoveDirection, displays: [DisplayInfo], wraps: Bool, animate: Bool
    ) -> Result<MoveReceipt, MoveFailure> {
        guard processID != ProcessInfo.processInfo.processIdentifier else { return .failure(.notMovable) }
        guard displays.count > 1 else { return .failure(.singleDisplay) }
        let application = AXUIElementCreateApplication(processID)
        let timeout = Float(responseTimeoutMilliseconds) / 1000
        AXUIElementSetMessagingTimeout(application, timeout)
        guard let window = windowAttribute(application, kAXFocusedWindowAttribute)
            ?? windowAttribute(application, kAXMainWindowAttribute) else { return .failure(.noWindow) }
        AXUIElementSetMessagingTimeout(window, timeout)
        if boolAttribute(window, "AXFullScreen") { return .failure(.fullScreen) }
        if boolAttribute(window, kAXMinimizedAttribute) { return .failure(.noWindow) }
        guard let frame = frame(of: window), frame.width > 0, frame.height > 0,
              let sourceIndex = DisplayLayout.sourceIndex(for: frame, in: displays) else {
            return .failure(.readFailed)
        }
        guard let destinationIndex = DisplayLayout.destinationIndex(
            from: sourceIndex, direction: direction, count: displays.count, wraps: wraps
        ) else { return .failure(.edge(direction)) }
        guard isSettable(window, kAXPositionAttribute) else { return .failure(.notMovable) }

        let canResize = isSettable(window, kAXSizeAttribute)
        let target = displays[destinationIndex]
        let proposed = DisplayLayout.placement(
            for: frame, from: displays[sourceIndex], to: target, canResize: canResize
        )
        let animatePosition: ((CGPoint, CGPoint) -> Void)? = animate ? { start, end in
            // A slow client can skip the intermediate writes and still receive
            // the final position with the normal AX timeout.
            AXUIElementSetMessagingTimeout(window, 0.05)
            defer { AXUIElementSetMessagingTimeout(window, timeout) }
            WindowMoveAnimation.slide(from: start, to: end) { setPosition(window, $0) == .success }
        } : nil
        guard placeWindow(from: frame, to: proposed, in: target.visibleFrame, canResize: canResize,
                          animatePosition: animatePosition,
                          readFrame: { Self.frame(of: window) },
                          setPosition: { setPosition(window, $0) == .success },
                          setSize: { _ = setSize(window, $0) },
                          isOnDestination: { DisplayLayout.sourceIndex(for: $0, in: displays) == destinationIndex })
        else { return .failure(.moveFailed) }
        return .success(MoveReceipt(displayName: target.name))
    }

    static func placeWindow(
        from original: CGRect, to proposed: CGRect, in visibleFrame: CGRect, canResize: Bool,
        animatePosition: ((CGPoint, CGPoint) -> Void)? = nil,
        readFrame: () -> CGRect?, setPosition: (CGPoint) -> Bool, setSize: (CGSize) -> Void,
        isOnDestination: (CGRect) -> Bool
    ) -> Bool {
        let smaller = CGSize(width: min(original.width, proposed.width), height: min(original.height, proposed.height))
        if canResize && smaller != original.size { setSize(smaller) }
        animatePosition?(original.origin, proposed.origin)
        guard setPosition(proposed.origin), var actual = readFrame() else { return false }
        if canResize && actual.size != proposed.size {
            setSize(proposed.size)
            guard let resized = readFrame() else { return false }
            actual = resized
        }
        // Some apps enforce a minimum size or shift the window when resizing it.
        let desired = DisplayLayout.clampedOrigin(for: CGRect(origin: proposed.origin, size: actual.size), in: visibleFrame)
        if abs(actual.minX - desired.x) > 1 || abs(actual.minY - desired.y) > 1 {
            guard setPosition(desired), let corrected = readFrame() else { return false }
            actual = corrected
        }
        let closeToRequested = abs(actual.minX - desired.x) <= 12 && abs(actual.minY - desired.y) <= 12
        return closeToRequested || isOnDestination(actual)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func windowAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool {
        (attribute(element, name) as? NSNumber)?.boolValue ?? false
    }

    private static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        let names = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(window, names, [], &values)
        if error == .success, let pair = values as? [AnyObject], pair.count == 2,
           let rect = rect(position: pair[0], size: pair[1]) { return rect }
        // A client may implement single-attribute reads only, or return AX error
        // values for individual entries. Don't repeat a request that timed out.
        guard error == .success || error == .notImplemented || error == .attributeUnsupported else { return nil }
        return rect(position: attribute(window, kAXPositionAttribute), size: attribute(window, kAXSizeAttribute))
    }

    private static func rect(position positionValue: CFTypeRef?, size sizeValue: CFTypeRef?) -> CGRect? {
        guard let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        let positionAX = positionValue as! AXValue
        let sizeAX = sizeValue as! AXValue
        guard AXValueGetType(positionAX) == .cgPoint, AXValueGetType(sizeAX) == .cgSize else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &position), AXValueGetValue(sizeAX, .cgSize, &size),
              position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func setPosition(_ window: AXUIElement, _ position: CGPoint) -> AXError {
        var value = position
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return .failure }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, axValue)
    }

    private static func setSize(_ window: AXUIElement, _ size: CGSize) -> AXError {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else { return .failure }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axValue)
    }
}

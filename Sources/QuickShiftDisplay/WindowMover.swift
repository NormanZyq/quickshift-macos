import ApplicationServices
import CoreGraphics
import Foundation
import QuickShiftCore

struct MoveReceipt: Sendable { let displayName: String }

enum MoveFailure: LocalizedError, Sendable {
    case singleDisplay, edge(MoveDirection), noWindow, fullScreen, notMovable, readFailed, moveFailed

    var errorDescription: String? {
        switch self {
        case .singleDisplay: "连接另一台显示器后即可移屏"
        case .edge(let direction): direction == .left ? "已经是最左侧屏幕" : "已经是最右侧屏幕"
        case .noWindow: "当前应用没有可移动的窗口"
        case .fullScreen: "请先退出系统全屏，再移动窗口"
        case .notMovable: "这个窗口不支持通过辅助功能移动"
        case .readFailed: "无法读取窗口，请检查辅助功能权限"
        case .moveFailed: "应用未响应移屏操作，请重试"
        }
    }
}

/// AX IPC can block on another app. Keep it off the event tap's main run loop.
final class WindowMover: Sendable {
    private let queue = DispatchQueue(label: "local.quickshiftdisplay.window-mover", qos: .userInteractive)

    func move(
        processID: pid_t, direction: MoveDirection, displays: [DisplayInfo], wraps: Bool,
        completion: @escaping @MainActor @Sendable (Result<MoveReceipt, MoveFailure>) -> Void
    ) {
        queue.async {
            let result = Self.performMove(processID: processID, direction: direction, displays: displays, wraps: wraps)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func performMove(
        processID: pid_t, direction: MoveDirection, displays: [DisplayInfo], wraps: Bool
    ) -> Result<MoveReceipt, MoveFailure> {
        guard displays.count > 1 else { return .failure(.singleDisplay) }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.6)
        guard let window = windowAttribute(application, kAXFocusedWindowAttribute)
            ?? windowAttribute(application, kAXMainWindowAttribute) else { return .failure(.noWindow) }
        AXUIElementSetMessagingTimeout(window, 0.6)
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
        // Shrink before moving, expand afterwards. A final position write handles app minimum sizes
        // and apps that constrain their position during a size change.
        if canResize {
            _ = setSize(window, CGSize(width: min(frame.width, proposed.width), height: min(frame.height, proposed.height)))
        }
        guard setPosition(window, proposed.origin) == .success else { return .failure(.moveFailed) }
        if canResize { _ = setSize(window, proposed.size) }
        var finalFrame = proposed
        if let actual = Self.frame(of: window) { finalFrame.size = actual.size }
        finalFrame.origin = DisplayLayout.clampedOrigin(for: finalFrame, in: target.visibleFrame)
        guard setPosition(window, finalFrame.origin) == .success else { return .failure(.moveFailed) }

        // AX success alone is not enough: some applications ignore a position write.
        guard let actual = Self.frame(of: window) else { return .failure(.moveFailed) }
        let closeToRequested = abs(actual.minX - finalFrame.minX) <= 12 && abs(actual.minY - finalFrame.minY) <= 12
        guard closeToRequested || DisplayLayout.sourceIndex(for: actual, in: displays) == destinationIndex else {
            return .failure(.moveFailed)
        }
        return .success(MoveReceipt(displayName: target.name))
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
        guard let positionValue = attribute(window, kAXPositionAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = attribute(window, kAXSizeAttribute), CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        let positionAX = positionValue as! AXValue
        let sizeAX = sizeValue as! AXValue
        guard AXValueGetType(positionAX) == .cgPoint, AXValueGetType(sizeAX) == .cgSize else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &position), AXValueGetValue(sizeAX, .cgSize, &size),
              position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite else { return nil }
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

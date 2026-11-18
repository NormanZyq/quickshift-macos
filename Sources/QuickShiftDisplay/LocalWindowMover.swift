import AppKit
import QuickShiftCore

/// Local windows use AppKit on the main actor; other processes use the AX worker.
@MainActor
enum LocalWindowMover {
    static func move(window: NSWindow?, direction: MoveDirection, displays: [DisplayInfo], wraps: Bool)
        -> Result<MoveReceipt, MoveFailure> {
        guard displays.count > 1 else { return .failure(.singleDisplay) }
        guard let activeWindow = window else { return .failure(.noWindow) }
        let window = activeWindow.sheetParent ?? activeWindow
        guard window.isVisible, !window.isMiniaturized else { return .failure(.noWindow) }
        guard !window.styleMask.contains(.fullScreen) else { return .failure(.fullScreen) }
        guard window.isMovable else { return .failure(.notMovable) }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = DisplayLayout.accessibilityRect(fromAppKit: window.frame, primaryTop: primaryTop)
        guard let sourceIndex = DisplayLayout.sourceIndex(for: frame, in: displays) else { return .failure(.readFailed) }
        guard let destinationIndex = DisplayLayout.destinationIndex(
            from: sourceIndex, direction: direction, count: displays.count, wraps: wraps
        ) else { return .failure(.edge(direction)) }
        let target = displays[destinationIndex]
        let proposed = DisplayLayout.placement(for: frame, from: displays[sourceIndex], to: target,
                                               canResize: window.styleMask.contains(.resizable))
        window.setFrame(DisplayLayout.appKitRect(fromAccessibility: proposed, primaryTop: primaryTop),
                        display: true, animate: false)
        var actual = DisplayLayout.accessibilityRect(fromAppKit: window.frame, primaryTop: primaryTop)
        actual.origin = DisplayLayout.clampedOrigin(for: actual, in: target.visibleFrame)
        let corrected = DisplayLayout.appKitRect(fromAccessibility: actual, primaryTop: primaryTop)
        if window.frame.origin != corrected.origin { window.setFrameOrigin(corrected.origin) }
        let finalFrame = DisplayLayout.accessibilityRect(fromAppKit: window.frame, primaryTop: primaryTop)
        guard DisplayLayout.sourceIndex(for: finalFrame, in: displays) == destinationIndex else {
            return .failure(.moveFailed)
        }
        return .success(MoveReceipt(displayName: target.name))
    }
}

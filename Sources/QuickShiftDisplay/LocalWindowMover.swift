import AppKit
import QuickShiftCore
import QuartzCore

/// Local windows use AppKit on the main actor; other processes use the AX worker.
@MainActor
enum LocalWindowMover {
    static func move(window: NSWindow?, direction: MoveDirection, displays: [DisplayInfo], wraps: Bool,
                     animate: Bool, completion: @escaping WindowMover.Completion) {
        guard displays.count > 1 else { completion(.failure(.singleDisplay)); return }
        guard let activeWindow = window else { completion(.failure(.noWindow)); return }
        let window = activeWindow.sheetParent ?? activeWindow
        guard window.isVisible, !window.isMiniaturized else { completion(.failure(.noWindow)); return }
        guard !window.styleMask.contains(.fullScreen) else { completion(.failure(.fullScreen)); return }
        guard window.isMovable else { completion(.failure(.notMovable)); return }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = DisplayLayout.accessibilityRect(fromAppKit: window.frame, primaryTop: primaryTop)
        guard let sourceIndex = DisplayLayout.sourceIndex(for: frame, in: displays) else { completion(.failure(.readFailed)); return }
        guard let destinationIndex = DisplayLayout.destinationIndex(
            from: sourceIndex, direction: direction, count: displays.count, wraps: wraps
        ) else { completion(.failure(.edge(direction))); return }
        let target = displays[destinationIndex]
        let proposed = DisplayLayout.placement(for: frame, from: displays[sourceIndex], to: target,
                                               canResize: window.styleMask.contains(.resizable))
        let destination = DisplayLayout.appKitRect(fromAccessibility: proposed, primaryTop: primaryTop)
        let finish = { @MainActor in
            completion(verify(window: window, displays: displays, destinationIndex: destinationIndex, primaryTop: primaryTop))
        }
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = WindowMoveAnimation.duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(destination, display: true)
            } completionHandler: {
                Task { @MainActor in finish() }
            }
        } else {
            window.setFrame(destination, display: true, animate: false)
            finish()
        }
    }

    private static func verify(window: NSWindow, displays: [DisplayInfo], destinationIndex: Int,
                               primaryTop: CGFloat) -> Result<MoveReceipt, MoveFailure> {
        guard window.isVisible, !window.isMiniaturized else { return .failure(.noWindow) }
        guard !window.styleMask.contains(.fullScreen) else { return .failure(.fullScreen) }
        let target = displays[destinationIndex]
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

import CoreGraphics
import Foundation
import QuickShiftCore
import Testing
@testable import QuickShiftDisplay

private func testMonitor() -> GlobalShortcutMonitor {
    GlobalShortcutMonitor(statusURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("QuickShift-\(UUID().uuidString).state"))
}

// These tests construct in-memory events only. They never install a global tap or post input.
@Test @MainActor func matchedInputReturnsWhileMainThreadIsBlockedAndKeepsForegroundSnapshot() async {
    let monitor = testMonitor()
    monitor.foregroundProcessID = 123
    let finished = DispatchSemaphore(value: 0)
    let receipt = await withCheckedContinuation { (continuation: CheckedContinuation<(MoveDirection, Int32?), Never>) in
        monitor.onShortcut = { direction, processID in continuation.resume(returning: (direction, processID)) }
        DispatchQueue.global(qos: .userInteractive).async {
            let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
            event.flags = [.maskControl, .maskCommand, .maskShift]
            #expect(monitor.handle(type: .leftMouseDown, event: event))
            finished.signal()
        }
        // A synchronous hop to AppKit/main would fail this check. The real event filter must
        // return first; only the move request is allowed to wait for the UI queue.
        #expect(finished.wait(timeout: .now() + 0.25) == .success)
        monitor.foregroundProcessID = 456
    }
    #expect(receipt.0 == .left)
    #expect(receipt.1 == 123)
}

@Test @MainActor func ordinaryMouseInputDoesNotDependOnMainThread() {
    let monitor = testMonitor()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInteractive).async {
        for _ in 0..<128 {
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: .zero, mouseButton: .left)!
            #expect(!monitor.handle(type: .leftMouseDown, event: down))
            #expect(!monitor.handle(type: .leftMouseUp, event: up))
        }
        finished.signal()
    }
    #expect(finished.wait(timeout: .now() + 0.25) == .success)
}

@Test func nativeRightMousePressAndReleaseAreMatchedAsOneSequence() {
    let monitor = testMonitor()
    let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: .zero, mouseButton: .right)!
    down.flags = [.maskControl, .maskCommand, .maskShift]
    #expect(monitor.handle(type: .rightMouseDown, event: down))
    let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: .zero, mouseButton: .right)!
    #expect(monitor.handle(type: .rightMouseUp, event: up))
    down.flags = []
    #expect(!monitor.handle(type: .rightMouseDown, event: down))
}

@Test func nativeTimeoutClearsCapturedPressState() {
    let monitor = testMonitor()
    let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
    down.flags = [.maskControl, .maskCommand, .maskShift]
    #expect(monitor.handle(type: .leftMouseDown, event: down))
    #expect(!monitor.handle(type: .tapDisabledByTimeout, event: down))
    down.flags = []
    #expect(!monitor.handle(type: .leftMouseDown, event: down))
}

@Test func queuedStartupDisableNotificationDoesNotLatchAFault() {
    let monitor = testMonitor()
    let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
    down.flags = [.maskControl, .maskCommand, .maskShift]
    #expect(!monitor.handle(type: .tapDisabledByUserInput, event: down))
    #expect(monitor.handle(type: .leftMouseDown, event: down))
}

@Test @MainActor func timeoutCannotBeReenabledByPollingOrPermissionChanges() {
    let monitor = testMonitor()
    let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
    down.flags = [.maskControl, .maskCommand, .maskShift]
    #expect(!monitor.handle(type: .tapDisabledByTimeout, event: down))
    #expect(monitor.isSafelySuspended)
    #expect(!monitor.handle(type: .leftMouseDown, event: down))
    #expect(!monitor.start()) // The fault guard returns before any native tap can be created.
    monitor.stop() // Mirrors a permission revocation while the app is running.
    #expect(!monitor.start())
    #expect(monitor.isSafelySuspended)
    monitor.resetSuspensionForUserRequest()
    #expect(!monitor.isSafelySuspended)
    #expect(monitor.handle(type: .leftMouseDown, event: down))
}

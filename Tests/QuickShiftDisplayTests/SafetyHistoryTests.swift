import CoreGraphics
import Foundation
import InputSafety
import Testing
@testable import QuickShiftDisplay

private func createStatus(at url: URL, withFault: Bool) throws {
    let native = try #require(url.path.withCString { QSDNativeInputCreate($0, 0) })
    if withFault { _ = QSDNativeInputRouteForTesting(native, .tapDisabledByTimeout, nil) }
    QSDNativeInputDestroy(native)
}

@Test func previousSafetyExitSurvivesStartingANewMonitor() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("QuickShift-history-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("input.state")
    try createStatus(at: url, withFault: true)
    let monitor = GlobalShortcutMonitor(statusURL: url)
    let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                    mouseCursorPosition: .zero, mouseButton: .left))
    #expect(!monitor.handle(type: .leftMouseDown, event: event))
    #expect(GlobalShortcutMonitor.readStatus(at: url)?.fault == 0)
    #expect(GlobalShortcutMonitor.readStatus(at: GlobalShortcutMonitor.previousFaultURL(for: url))?.fault == 4)
}

@Test func healthyRunDoesNotOverwritePreviousSafetyExit() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("QuickShift-history-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("input.state")
    try createStatus(at: url, withFault: true)
    #expect(GlobalShortcutMonitor.preservePreviousFault(at: url))
    try createStatus(at: url, withFault: false)
    #expect(!GlobalShortcutMonitor.preservePreviousFault(at: url))
    #expect(GlobalShortcutMonitor.readStatus(at: GlobalShortcutMonitor.previousFaultURL(for: url))?.fault == 4)
}

@Test func secondListenerCannotEraseTheOwnersSafetyState() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("QuickShift-owner-\(UUID()).state")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        let owner = try #require(url.path.withCString { QSDNativeInputCreate($0, 0) })
        defer { QSDNativeInputDestroy(owner) }
        _ = QSDNativeInputRouteForTesting(owner, .tapDisabledByTimeout, nil)
        let duplicate = url.path.withCString { QSDNativeInputCreate($0, 0) }
        defer { if let duplicate { QSDNativeInputDestroy(duplicate) } }
        #expect(duplicate == nil)
        #expect(GlobalShortcutMonitor.readStatus(at: url)?.fault == 4)
        #expect(QSDNativeInputFault(owner) == 4)
    }
    let replacement = try #require(url.path.withCString { QSDNativeInputCreate($0, 0) })
    defer { QSDNativeInputDestroy(replacement) }
    #expect(QSDNativeInputFault(replacement) == 0)
}

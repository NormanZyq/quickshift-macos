import Foundation
import QuickShiftCore
import Testing
@testable import QuickShiftDisplay

@Test @MainActor func ownWindowMovementNeverEntersTheAXWorker() async {
    let mover = WindowMover(ownMove: { direction, _, wraps in
        #expect(Thread.isMainThread)
        #expect(direction == .left)
        #expect(wraps)
        return .success(MoveReceipt(displayName: "Local destination"))
    }, externalMove: { _, _, _, _ in
        Issue.record("A self-directed move must not use AX on the background thread")
        return .failure(.moveFailed)
    })
    let result = await withCheckedContinuation { continuation in
        mover.move(processID: ProcessInfo.processInfo.processIdentifier, direction: .left, displays: [], wraps: true) {
            continuation.resume(returning: $0)
        }
    }
    if case let .success(receipt) = result { #expect(receipt.displayName == "Local destination") }
    else { Issue.record("The local move was not delivered") }
}

@Test @MainActor func externalWindowMovementStaysOffTheMainThread() async {
    let targetPID = ProcessInfo.processInfo.processIdentifier + 100_000
    let mover = WindowMover(ownMove: { _, _, _ in
        Issue.record("An external window must use the AX worker")
        return .failure(.moveFailed)
    }, externalMove: { processID, direction, _, wraps in
        #expect(!Thread.isMainThread)
        #expect(processID == targetPID)
        #expect(direction == .right)
        #expect(!wraps)
        return .success(MoveReceipt(displayName: "External destination"))
    })
    let result = await withCheckedContinuation { continuation in
        mover.move(processID: targetPID, direction: .right, displays: [], wraps: false) {
            continuation.resume(returning: $0)
        }
    }
    if case let .success(receipt) = result { #expect(receipt.displayName == "External destination") }
    else { Issue.record("The external move was not delivered") }
}

@Test(arguments: [true, false])
func normalMoveNeedsOnePositionWriteAndOneFrameRead(canResize: Bool) {
    var frame = CGRect(x: 40, y: 20, width: 800, height: 500)
    let proposed = frame.offsetBy(dx: 1200, dy: 0)
    var positionWrites = 0, frameReads = 0
    let moved = WindowMover.placeWindow(from: frame, to: proposed,
        in: CGRect(x: 1200, y: 0, width: 1200, height: 800), canResize: canResize,
        readFrame: { frameReads += 1; return frame },
        setPosition: { positionWrites += 1; frame.origin = $0; return true },
        setSize: { _ in Issue.record("An unchanged size should not be written") },
        isOnDestination: { _ in false })
    #expect(moved && frame == proposed)
    #expect(positionWrites == 1 && frameReads == 1)
}

@Test func expansionRepositionsAWindowThatEnforcesAMinimumSize() {
    var frame = CGRect(x: 0, y: 0, width: 960, height: 700)
    let area = CGRect(x: 1000, y: 20, width: 1200, height: 800)
    var writes = [String]()
    let moved = WindowMover.placeWindow(from: frame, to: area, in: area, canResize: true,
        readFrame: { frame },
        setPosition: { writes.append("position"); frame.origin = $0; return true },
        setSize: { size in
            writes.append("size")
            frame.size = CGSize(width: size.width + 50, height: size.height)
            frame.origin.x -= 50
        }, isOnDestination: { _ in false })
    #expect(moved && frame.origin == area.origin)
    #expect(writes == ["position", "size", "position"])
}

@Test func smallerDestinationShrinksOnceBeforeMoving() {
    var frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let area = CGRect(x: 1200, y: 20, width: 900, height: 650)
    var writes = [String]()
    let moved = WindowMover.placeWindow(from: frame, to: area, in: area, canResize: true,
        readFrame: { frame }, setPosition: { writes.append("position"); frame.origin = $0; return true },
        setSize: { writes.append("size"); frame.size = $0 }, isOnDestination: { _ in false })
    #expect(moved && frame == area)
    #expect(writes == ["size", "position"])
}

@Test(arguments: [true, false])
func ignoredOrUnreadableWindowDoesNotReportSuccess(canRead: Bool) {
    let frame = CGRect(x: 0, y: 0, width: 800, height: 500)
    let proposed = frame.offsetBy(dx: 1200, dy: 0)
    #expect(!WindowMover.placeWindow(from: frame, to: proposed, in: proposed, canResize: false,
        readFrame: { canRead ? frame : nil }, setPosition: { _ in true }, setSize: { _ in },
        isOnDestination: { _ in false }))
}

@Test @MainActor func busyExternalClientDoesNotReplayOldShortcuts() async {
    let gate = DispatchSemaphore(value: 0)
    let firstPID = ProcessInfo.processInfo.processIdentifier + 1
    let mover = WindowMover(externalMove: { pid, _, _, _ in
        #expect(pid == firstPID)
        #expect(gate.wait(timeout: .now() + 3) == .success)
        return .success(MoveReceipt(displayName: "Destination"))
    })
    let (outcomes, stream) = AsyncStream<(Int, Bool)>.makeStream()
    // The first request is in flight. Further requests queue, then expire.
    for index in 0..<5 {
        mover.move(processID: firstPID + Int32(index), direction: .right, displays: [], wraps: true) { result in
            if case .failure(.busy) = result { stream.yield((index, true)) }
            else { stream.yield((index, false)) }
        }
    }
    var iterator = outcomes.makeAsyncIterator()
    let first = await iterator.next()
    #expect(first?.0 == 4 && first?.1 == true)
    try? await Task.sleep(for: .milliseconds(700))
    gate.signal()
    for index in 0..<4 {
        let outcome = await iterator.next()
        #expect(outcome?.0 == index && outcome?.1 == (index != 0))
    }
    stream.finish()
}

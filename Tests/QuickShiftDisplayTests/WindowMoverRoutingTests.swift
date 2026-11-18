import Foundation
import QuickShiftCore
import Testing
@testable import QuickShiftDisplay

@Test @MainActor func ownWindowMovementNeverEntersTheAXWorker() async {
    let mover = WindowMover(ownMove: { _, direction, _, wraps, animate, finish in
        MainActor.preconditionIsolated()
        #expect(direction == .left)
        #expect(wraps)
        #expect(animate)
        finish(.success(MoveReceipt(displayName: "Local destination")))
    }, externalMove: { _, _, _, _, _ in
        Issue.record("A self-directed move must not use AX on the background thread")
        return .failure(.moveFailed)
    })
    let result = await withCheckedContinuation { continuation in
        mover.move(processID: ProcessInfo.processInfo.processIdentifier, direction: .left, displays: [], wraps: true, animate: true) {
            continuation.resume(returning: $0)
        }
    }
    if case let .success(receipt) = result { #expect(receipt.displayName == "Local destination") }
    else { Issue.record("The local move was not delivered") }
}

@Test @MainActor func externalWindowMovementStaysOffTheMainThread() async {
    let targetPID = ProcessInfo.processInfo.processIdentifier + 100_000
    let mover = WindowMover(ownMove: { _, _, _, _, _, finish in
        Issue.record("An external window must use the AX worker")
        finish(.failure(.moveFailed))
    }, externalMove: { processID, direction, _, wraps, animate in
        #expect(!Thread.isMainThread)
        #expect(processID == targetPID)
        #expect(direction == .right)
        #expect(!wraps)
        #expect(animate)
        return .success(MoveReceipt(displayName: "External destination"))
    })
    let result = await withCheckedContinuation { continuation in
        mover.move(processID: targetPID, direction: .right, displays: [], wraps: false, animate: true) {
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

@Test func animatedMoveGlidesAcrossBothAxesThenVerifiesOneLanding() throws {
    var frame = CGRect(x: -1280, y: -200, width: 480, height: 320)
    let target = frame.offsetBy(dx: 1600, dy: 800)
    var time = 0.0
    var points: [CGPoint] = []
    var reads = 0
    func write(_ point: CGPoint) -> Bool {
        points.append(point)
        frame.origin = point
        return true
    }
    let moved = WindowMover.placeWindow(from: frame, to: target, in: target, canResize: true,
        animatePosition: { from, to in
            WindowMoveAnimation.slide(from: from, to: to, now: { time }, sleep: { time += $0 }, setPosition: write)
        }, readFrame: { reads += 1; return frame }, setPosition: write,
        setSize: { _ in Issue.record("The slide should only change position") }, isOnDestination: { _ in false })
    #expect(moved && reads == 1 && points.last == target.origin)
    try #require(points.count == 12)
    #expect(zip(points, points.dropFirst()).allSatisfy { $0.x < $1.x && $0.y < $1.y })
    #expect(points[6].x - points[5].x > points[1].x - points[0].x)
    #expect(abs(time - WindowMoveAnimation.duration) < 0.0001)
}

@Test(arguments: [true, false])
func interruptedOrSlowAnimationStillCommitsTheExactDestination(rejectIntermediate: Bool) {
    var frame = CGRect(x: 420, y: 60, width: 480, height: 320)
    let target = frame.offsetBy(dx: -1200, dy: -160)
    var time = 0.0, intermediateWrites = 0, finalWrites = 0
    let moved = WindowMover.placeWindow(from: frame, to: target, in: target, canResize: false,
        animatePosition: { from, to in
            WindowMoveAnimation.slide(from: from, to: to, now: { time }, sleep: { time += $0 }) { point in
                intermediateWrites += 1
                if rejectIntermediate { return false }
                frame.origin = point
                time += 0.3
                return true
            }
        }, readFrame: { frame }, setPosition: { finalWrites += 1; frame.origin = $0; return true },
        setSize: { _ in }, isOnDestination: { _ in false })
    #expect(moved && frame == target)
    #expect(intermediateWrites == 1 && finalWrites == 1)
}

@Test @MainActor func localShortcutBurstUsesSettledGeometryWithoutStackingAnimations() async {
    var completed = 0
    var motions: [Bool] = []
    let mover = WindowMover(ownMove: { _, _, _, _, animate, finish in
        let before = completed
        Task { @MainActor in
            await Task.yield()
            #expect(completed == before)
            completed += 1
            motions.append(animate)
            finish(.success(MoveReceipt(displayName: "Destination")))
        }
    })
    let (events, stream) = AsyncStream<Void>.makeStream()
    func submit() {
        mover.move(processID: ProcessInfo.processInfo.processIdentifier, direction: .right,
                   displays: [], wraps: true, animate: true) { _ in stream.yield(()) }
    }
    var iterator = events.makeAsyncIterator()
    for _ in 0..<3 { submit() }
    for _ in 0..<3 { _ = await iterator.next() }
    submit()
    _ = await iterator.next()
    stream.finish()
    #expect(motions == [true, false, false, true])
}

@Test @MainActor func instantLocalMovesCompleteInTheCurrentEvent() {
    var completed = 0
    let mover = WindowMover(ownMove: { _, _, _, _, animate, finish in
        #expect(!animate)
        finish(.success(MoveReceipt(displayName: "Destination")))
    })
    for _ in 0..<6 {
        mover.move(processID: ProcessInfo.processInfo.processIdentifier, direction: .left,
                   displays: [], wraps: true) { _ in completed += 1 }
    }
    #expect(completed == 6)
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
    let mover = WindowMover(externalMove: { pid, _, _, _, _ in
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

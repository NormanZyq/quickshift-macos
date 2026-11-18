import Foundation

enum WindowMoveAnimation {
    static let duration: TimeInterval = 0.2
    private static let intervals = 12

    /// Run only on the serial AX worker. The caller owns the final verified
    /// placement. Late replies skip missed frames instead of extending the slide.
    static func slide(
        from start: CGPoint, to end: CGPoint,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        setPosition: (CGPoint) -> Bool
    ) {
        guard start != end else { return }
        let began = now()
        var last = start
        for tick in 1...intervals {
            let deadline = began + duration * Double(tick) / Double(intervals)
            let wait = deadline - now()
            if wait <= 0 { continue }
            sleep(wait)
            let progress = (now() - began) / duration
            guard tick < intervals, progress < 1 else { return }
            let eased = progress * progress * (3 - 2 * progress)
            let point = CGPoint(x: (start.x + (end.x - start.x) * eased).rounded(),
                                y: (start.y + (end.y - start.y) * eased).rounded())
            if point == end { return }
            if point == last { continue }
            guard setPosition(point) else { return }
            last = point
        }
    }
}

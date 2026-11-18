import CoreGraphics
import Foundation

/// All geometry uses Accessibility coordinates: points, origin at the primary display's top left.
public struct DisplayInfo: Sendable, Equatable {
    public let id: UInt32
    public let name: String
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(id: UInt32, name: String, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

public enum DisplayLayout {
    public static func accessibilityRect(fromAppKit rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Horizontal centers define left/right; vertically aligned displays use top-to-bottom order.
    public static func ordered(_ displays: [DisplayInfo]) -> [DisplayInfo] {
        displays.sorted {
            if $0.frame.midX != $1.frame.midX { return $0.frame.midX < $1.frame.midX }
            if $0.frame.midY != $1.frame.midY { return $0.frame.midY < $1.frame.midY }
            return $0.id < $1.id
        }
    }

    public static func sourceIndex(for window: CGRect, in displays: [DisplayInfo]) -> Int? {
        guard !displays.isEmpty else { return nil }
        let center = CGPoint(x: window.midX, y: window.midY)
        var best = 0
        var bestArea: CGFloat = -1
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, display) in displays.enumerated() {
            let intersection = window.intersection(display.frame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            let dx = max(display.frame.minX - center.x, 0, center.x - display.frame.maxX)
            let dy = max(display.frame.minY - center.y, 0, center.y - display.frame.maxY)
            let distance = dx * dx + dy * dy
            if area > bestArea || (area == bestArea && distance < bestDistance) {
                best = index
                bestArea = area
                bestDistance = distance
            }
        }
        return best
    }

    public static func destinationIndex(
        from source: Int, direction: MoveDirection, count: Int, wraps: Bool
    ) -> Int? {
        guard count > 1, (0..<count).contains(source) else { return nil }
        let next = source + (direction == .left ? -1 : 1)
        if (0..<count).contains(next) { return next }
        return wraps ? (next + count) % count : nil
    }

    public static func placement(
        for window: CGRect, from source: DisplayInfo, to target: DisplayInfo, canResize: Bool
    ) -> CGRect {
        let oldArea = source.visibleFrame
        let newArea = target.visibleFrame
        let fillsScreen = abs(window.minX - oldArea.minX) <= 4
            && abs(window.minY - oldArea.minY) <= 4
            && abs(window.width - oldArea.width) <= 4
            && abs(window.height - oldArea.height) <= 4
        if canResize && fillsScreen { return newArea }

        let size = CGSize(
            width: canResize ? min(window.width, newArea.width) : window.width,
            height: canResize ? min(window.height, newArea.height) : window.height
        )
        let xFraction = fraction(position: window.minX, size: window.width, start: oldArea.minX, length: oldArea.width)
        let yFraction = fraction(position: window.minY, size: window.height, start: oldArea.minY, length: oldArea.height)
        return CGRect(
            x: (newArea.minX + max(0, newArea.width - size.width) * xFraction).rounded(),
            y: (newArea.minY + max(0, newArea.height - size.height) * yFraction).rounded(),
            width: size.width, height: size.height
        )
    }

    /// Keep the title bar visible even when an app enforces a minimum size larger than the display.
    public static func clampedOrigin(for frame: CGRect, in visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(frame.minX, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - frame.width)),
            y: min(max(frame.minY, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - frame.height))
        )
    }

    private static func fraction(position: CGFloat, size: CGFloat, start: CGFloat, length: CGFloat) -> CGFloat {
        let travel = length - size
        guard travel > 1 else { return 0.5 }
        return min(1, max(0, (position - start) / travel))
    }
}

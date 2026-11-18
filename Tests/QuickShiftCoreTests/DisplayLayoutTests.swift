import CoreGraphics
import Foundation
import Testing
@testable import QuickShiftCore

private func display(_ id: UInt32, _ frame: CGRect, visible: CGRect? = nil) -> DisplayInfo {
    DisplayInfo(id: id, name: "Display \(id)", frame: frame, visibleFrame: visible ?? frame)
}

@Test func displayOrderUsesPositionRatherThanEnumeration() {
    let displays = [
        display(3, CGRect(x: 1000, y: 0, width: 1000, height: 800)),
        display(1, CGRect(x: -1000, y: 0, width: 1000, height: 800)),
        display(2, CGRect(x: 0, y: 0, width: 1000, height: 800)),
    ]
    #expect(DisplayLayout.ordered(displays).map(\.id) == [1, 2, 3])
}

@Test func verticallyAlignedDisplaysHaveStableOrder() {
    let displays = [
        display(2, CGRect(x: 0, y: 800, width: 1000, height: 800)),
        display(1, CGRect(x: 0, y: 0, width: 1000, height: 800)),
    ]
    #expect(DisplayLayout.ordered(displays).map(\.id) == [1, 2])
}

@Test func navigationWrapsInBothDirectionsAndStopsWhenDisabled() {
    #expect(DisplayLayout.destinationIndex(from: 0, direction: .left, count: 3, wraps: true) == 2)
    #expect(DisplayLayout.destinationIndex(from: 2, direction: .right, count: 3, wraps: true) == 0)
    #expect(DisplayLayout.destinationIndex(from: 0, direction: .left, count: 3, wraps: false) == nil)
    #expect(DisplayLayout.destinationIndex(from: 2, direction: .right, count: 3, wraps: false) == nil)
    #expect(DisplayLayout.destinationIndex(from: 1, direction: .left, count: 3, wraps: false) == 0)
    #expect(DisplayLayout.destinationIndex(from: 1, direction: .right, count: 3, wraps: false) == 2)
}

@Test func navigationHandlesOneScreenAndInvalidIndices() {
    #expect(DisplayLayout.destinationIndex(from: 0, direction: .left, count: 1, wraps: true) == nil)
    #expect(DisplayLayout.destinationIndex(from: 0, direction: .right, count: 0, wraps: true) == nil)
    #expect(DisplayLayout.destinationIndex(from: 3, direction: .right, count: 3, wraps: true) == nil)
}

@Test func coordinateConversionHandlesScreensAboveAndLeftOfPrimary() {
    let rect = CGRect(x: -1440, y: 900, width: 1440, height: 900)
    #expect(DisplayLayout.accessibilityRect(fromAppKit: rect, primaryTop: 900)
            == CGRect(x: -1440, y: -900, width: 1440, height: 900))
    let visible = CGRect(x: 0, y: 40, width: 1440, height: 835)
    #expect(DisplayLayout.accessibilityRect(fromAppKit: visible, primaryTop: 900)
            == CGRect(x: 0, y: 25, width: 1440, height: 835))
}

@Test func windowBelongsToScreenWithLargestIntersection() {
    let displays = [
        display(1, CGRect(x: 0, y: 0, width: 1000, height: 800)),
        display(2, CGRect(x: 1000, y: 0, width: 1000, height: 800)),
    ]
    #expect(DisplayLayout.sourceIndex(for: CGRect(x: 900, y: 100, width: 500, height: 400), in: displays) == 1)
    #expect(DisplayLayout.sourceIndex(for: CGRect(x: -800, y: 100, width: 100, height: 100), in: displays) == 0)
    #expect(DisplayLayout.sourceIndex(for: .zero, in: []) == nil)
}

@Test func localWindowCoordinatesRoundTripAcrossDisplayOrigins() {
    for frame in [CGRect(x: 100, y: 150, width: 600, height: 780),
                  CGRect(x: -1400, y: 800, width: 600, height: 780),
                  CGRect(x: 2000, y: -500, width: 600, height: 780)] {
        let axFrame = DisplayLayout.accessibilityRect(fromAppKit: frame, primaryTop: 1080)
        #expect(DisplayLayout.appKitRect(fromAccessibility: axFrame, primaryTop: 1080) == frame)
    }
}

@Test func normalWindowsKeepSizeAndRelativePosition() {
    let source = display(1, CGRect(x: 0, y: 0, width: 1000, height: 800),
                         visible: CGRect(x: 0, y: 24, width: 1000, height: 750))
    let target = display(2, CGRect(x: 1000, y: 0, width: 2000, height: 1000),
                         visible: CGRect(x: 1000, y: 24, width: 2000, height: 950))
    let proposed = DisplayLayout.placement(for: CGRect(x: 250, y: 174, width: 500, height: 450),
                                           from: source, to: target, canResize: true)
    #expect(proposed == CGRect(x: 1750, y: 274, width: 500, height: 450))
}

@Test func maximizedWindowsFillDestinationVisibleArea() {
    let source = display(1, CGRect(x: 0, y: 0, width: 1000, height: 800),
                         visible: CGRect(x: 0, y: 24, width: 1000, height: 750))
    let target = display(2, CGRect(x: -1400, y: -100, width: 1400, height: 1000),
                         visible: CGRect(x: -1400, y: -76, width: 1400, height: 950))
    #expect(DisplayLayout.placement(for: source.visibleFrame, from: source, to: target, canResize: true) == target.visibleFrame)
}

@Test func smallerDestinationShrinksResizableWindowsAndKeepsFixedTitleBarsVisible() {
    let source = display(1, CGRect(x: 0, y: 0, width: 1800, height: 1200))
    let target = display(2, CGRect(x: 1800, y: 0, width: 800, height: 600))
    let window = CGRect(x: 100, y: 100, width: 1200, height: 900)
    let resized = DisplayLayout.placement(for: window, from: source, to: target, canResize: true)
    #expect(resized == CGRect(x: 1800, y: 0, width: 800, height: 600))
    let fixed = DisplayLayout.placement(for: window, from: source, to: target, canResize: false)
    #expect(fixed == CGRect(x: 1800, y: 0, width: 1200, height: 900))
    #expect(DisplayLayout.clampedOrigin(for: CGRect(x: 2000, y: -50, width: 1200, height: 900), in: target.visibleFrame)
            == CGPoint(x: 1800, y: 0))
}

import AppKit
import CodexMetricsCore
import XCTest
@testable import CodexDashboard

final class StatusItemControllerTests: XCTestCase {
    private let panelSize = NSSize(width: 390, height: 620)

    func testPanelUsesScreenContainingStatusItemOnSecondDisplay() throws {
        let screens = [
            MenuPanelScreenGeometry(
                frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 876)
            ),
            MenuPanelScreenGeometry(
                frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080),
                visibleFrame: NSRect(x: 1440, y: 0, width: 1920, height: 1056)
            )
        ]
        let anchor = NSRect(x: 3000, y: 1020, width: 24, height: 24)

        let selected = menuPanelScreen(containing: anchor, screens: screens)

        XCTAssertEqual(selected, screens[1])
        let origin = menuPanelOrigin(anchor: anchor, size: panelSize, visibleFrame: try XCTUnwrap(selected?.visibleFrame))
        XCTAssertGreaterThanOrEqual(origin.x, screens[1].visibleFrame.minX + 8)
        XCTAssertLessThanOrEqual(origin.x + panelSize.width, screens[1].visibleFrame.maxX - 8)
    }

    func testPanelMovesAboveAnchorWhenThereIsNotEnoughRoomBelow() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = NSRect(x: 300, y: 4, width: 24, height: 24)

        let origin = menuPanelOrigin(anchor: anchor, size: panelSize, visibleFrame: visibleFrame)

        XCTAssertEqual(origin.y, anchor.maxY)
        XCTAssertGreaterThanOrEqual(origin.y, visibleFrame.minY + 8)
        XCTAssertLessThanOrEqual(origin.y + panelSize.height, visibleFrame.maxY - 8)
    }

    func testPanelRespectsNotchExcludedVisibleFrameAtTopEdge() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1512, height: 850)
        let anchor = NSRect(x: 744, y: 876, width: 24, height: 24)

        let origin = menuPanelOrigin(anchor: anchor, size: panelSize, visibleFrame: visibleFrame)

        XCTAssertGreaterThanOrEqual(origin.y, visibleFrame.minY + 8)
        XCTAssertLessThanOrEqual(origin.y + panelSize.height, visibleFrame.maxY - 8)
    }

    func testPanelOriginRemainsFiniteWhenScreenIsSmallerThanPanel() {
        let visibleFrame = NSRect(x: 100, y: 200, width: 300, height: 200)
        let anchor = NSRect(x: 220, y: 360, width: 24, height: 24)

        let origin = menuPanelOrigin(anchor: anchor, size: panelSize, visibleFrame: visibleFrame)

        XCTAssertTrue(origin.x.isFinite)
        XCTAssertTrue(origin.y.isFinite)
        XCTAssertEqual(origin.x, visibleFrame.minX + 8)
        XCTAssertEqual(origin.y, visibleFrame.minY + 8)
    }

    @MainActor
    func testTwoRowsIconReflectsEachQuotaInItsRow() throws {
        let weekly = UsageQuotaWindow(usedPercent: 2, windowMinutes: 10_080, resetsAt: Date(timeIntervalSince1970: 1))
        let fiveHour = UsageQuotaWindow(usedPercent: 50, windowMinutes: 300, resetsAt: Date(timeIntervalSince1970: 2))
        let changedWeekly = UsageQuotaWindow(usedPercent: 3, windowMinutes: 10_080, resetsAt: Date(timeIntervalSince1970: 1))
        let changedFiveHour = UsageQuotaWindow(usedPercent: 51, windowMinutes: 300, resetsAt: Date(timeIntervalSince1970: 2))

        let baseline = MenuBarQuotaIconRenderer.image(windows: [fiveHour, weekly], style: .twoRows)
        let weeklyChanged = MenuBarQuotaIconRenderer.image(windows: [fiveHour, changedWeekly], style: .twoRows)
        let fiveHourChanged = MenuBarQuotaIconRenderer.image(windows: [changedFiveHour, weekly], style: .twoRows)

        let baselineBytes = try bitmapBytes(for: baseline)
        let weeklyChangedBytes = try bitmapBytes(for: weeklyChanged)
        let fiveHourChangedBytes = try bitmapBytes(for: fiveHourChanged)
        let midpoint = baselineBytes.count / 2

        XCTAssertNotEqual(baselineBytes[..<midpoint], weeklyChangedBytes[..<midpoint])
        XCTAssertEqual(baselineBytes[midpoint...], weeklyChangedBytes[midpoint...])
        XCTAssertNotEqual(baselineBytes[midpoint...], fiveHourChangedBytes[midpoint...])
        XCTAssertEqual(baselineBytes[..<midpoint], fiveHourChangedBytes[..<midpoint])
    }

    @MainActor
    func testSwitchingIconStyleDoesNotReuseAnotherStyleImage() throws {
        let windows = [
            UsageQuotaWindow(usedPercent: 50, windowMinutes: 300, resetsAt: Date(timeIntervalSince1970: 2)),
            UsageQuotaWindow(usedPercent: 2, windowMinutes: 10_080, resetsAt: Date(timeIntervalSince1970: 1))
        ]

        let twoRows = MenuBarQuotaIconRenderer.image(windows: windows, style: .twoRows)
        let rings = MenuBarQuotaIconRenderer.image(windows: windows, style: .rings)

        XCTAssertNotEqual(try bitmapBytes(for: twoRows), try bitmapBytes(for: rings))
    }

    @MainActor
    func testTwoRowsIconTurnsQuotaRedWhenAttentionMarkerIsReached() throws {
        let weekly = UsageQuotaWindow(usedPercent: 2, windowMinutes: 10_080, resetsAt: Date(timeIntervalSince1970: 1))
        let untriggered = MenuBarQuotaIconRenderer.image(
            windows: [weekly],
            style: .twoRows,
            alertMarkers: .init(primary: 80, secondary: nil)
        )
        let reached = MenuBarQuotaIconRenderer.image(
            windows: [weekly],
            style: .twoRows,
            alertMarkers: .init(primary: 98, secondary: nil)
        )

        XCTAssertFalse(try containsRedPixel(in: untriggered))
        XCTAssertTrue(try containsRedPixel(in: reached))
    }

    @MainActor
    func testTwoRowsIconCentersWeeklyQuotaWhenFiveHourQuotaIsMissing() throws {
        let weekly = UsageQuotaWindow(usedPercent: 2, windowMinutes: 10_080, resetsAt: Date(timeIntervalSince1970: 1))
        let twoRows = MenuBarQuotaIconRenderer.image(
            windows: [weekly],
            style: .twoRows
        )
        let bounds = try alphaBounds(for: twoRows)

        XCTAssertEqual(bounds.midY, 18, accuracy: 3)
    }

    @MainActor
    func testTwoRowsIconShowsCenteredNAWhenQuotaIsUnavailable() throws {
        let twoRows = MenuBarQuotaIconRenderer.image(windows: [], style: .twoRows)
        let bounds = try alphaBounds(for: twoRows)

        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 0)
        XCTAssertEqual(bounds.midY, 18, accuracy: 3)
    }

    @MainActor
    func testTwoRowsIconKeepsFullWidthPercentageInsideCanvas() throws {
        let weekly = UsageQuotaWindow(usedPercent: 27, windowMinutes: 10_080, resetsAt: Date(timeIntervalSince1970: 1))
        let fiveHour = UsageQuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: Date(timeIntervalSince1970: 2))
        let twoRows = MenuBarQuotaIconRenderer.image(windows: [fiveHour, weekly], style: .twoRows)
        let bounds = try alphaBounds(for: twoRows)

        XCTAssertGreaterThan(bounds.minX, 0)
        XCTAssertLessThan(bounds.maxX, 36)
    }

    @MainActor
    private func bitmapBytes(for image: NSImage) throws -> [UInt8] {
        let representation = try XCTUnwrap(image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        let count = representation.bytesPerRow * representation.pixelsHigh
        return Array(UnsafeBufferPointer(start: representation.bitmapData, count: count))
    }

    @MainActor
    private func alphaBounds(for image: NSImage) throws -> CGRect {
        let representation = try XCTUnwrap(image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        var minX = representation.pixelsWide
        var minY = representation.pixelsHigh
        var maxX = -1
        var maxY = -1

        for y in 0..<representation.pixelsHigh {
            for x in 0..<representation.pixelsWide {
                guard representation.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.1 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        return CGRect(
            x: CGFloat(minX),
            y: CGFloat(minY),
            width: CGFloat(maxX - minX + 1),
            height: CGFloat(maxY - minY + 1)
        )
    }

    @MainActor
    private func containsRedPixel(in image: NSImage) throws -> Bool {
        let representation = try XCTUnwrap(image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        for y in 0..<representation.pixelsHigh {
            for x in 0..<representation.pixelsWide {
                guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.7,
                   color.redComponent > color.greenComponent * 1.5,
                   color.redComponent > color.blueComponent * 1.5 {
                    return true
                }
            }
        }
        return false
    }
}

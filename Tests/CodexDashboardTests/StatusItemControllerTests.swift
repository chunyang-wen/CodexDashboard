import AppKit
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
}

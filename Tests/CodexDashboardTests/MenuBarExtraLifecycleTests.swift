@testable import CodexDashboard
import XCTest

@MainActor
final class MenuBarExtraLifecycleTests: XCTestCase {
    func testPopoverCommandsAreSmallAndAuthenticatedByGeneration() {
        XCTAssertEqual(PopoverLifecycleCommand.openDashboard.rawValue, "openDashboard")
        XCTAssertEqual(PopoverLifecycleCommand.openSettings.rawValue, "openSettings")
        XCTAssertEqual(PopoverLifecycleCommand.quitProduct.rawValue, "quitProduct")
        XCTAssertNotEqual(
            PopoverProcessProtocol.hostToPopoverNotification,
            PopoverProcessProtocol.popoverToHostNotification
        )
        XCTAssertTrue(PopoverProcessProtocol.generationKey.contains("generation"))
    }

    func testPopoverCoordinatorDeduplicatesRequestsWhileLaunching() {
        let coordinator = PopoverProcessCoordinator(
            popoverURL: URL(fileURLWithPath: "/tmp/CodexDashboardPopoverUI-missing.app"),
            hostPID: 4242
        )

        coordinator.requestPopover(anchor: .zero)
        let generation = coordinator.currentGeneration
        XCTAssertEqual(coordinator.state, .launching)

        coordinator.requestPopover(anchor: NSRect(x: 20, y: 30, width: 18, height: 22))
        XCTAssertEqual(coordinator.currentGeneration, generation)
        XCTAssertEqual(coordinator.state, .launching)

        coordinator.helperDidTerminate()
        XCTAssertEqual(coordinator.state, .stopped)
    }
}

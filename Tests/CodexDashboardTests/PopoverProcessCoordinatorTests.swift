@testable import CodexDashboard
import Foundation
import XCTest

@MainActor
final class PopoverProcessCoordinatorTests: XCTestCase {
    func testPopoverStateCanRecoverAfterUnexpectedHelperExit() {
        let coordinator = PopoverProcessCoordinator(
            popoverURL: URL(fileURLWithPath: "/tmp/CodexDashboardPopoverUI-missing.app"),
            hostPID: 4242
        )

        coordinator.requestPopover(anchor: .zero)
        XCTAssertEqual(coordinator.state, .launching)
        coordinator.helperDidTerminate()
        XCTAssertEqual(coordinator.state, .stopped)
        XCTAssertNil(coordinator.currentPID)
        XCTAssertNil(coordinator.currentToken)
    }
}

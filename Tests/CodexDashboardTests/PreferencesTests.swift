@testable import CodexDashboard
import Foundation
import XCTest

final class PreferencesTests: XCTestCase {
    @MainActor
    func testDashboardRangePersistsAndDefaultsToMonth() {
        let suiteName = "PreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let userHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: userHome)
        }

        let initialStore = DashboardStore(userHome: userHome, defaults: defaults)
        XCTAssertEqual(initialStore.range, .month)

        initialStore.updateRange(.week)
        XCTAssertEqual(defaults.string(forKey: "dashboardRange"), "Week")

        let restoredStore = DashboardStore(userHome: userHome, defaults: defaults)
        XCTAssertEqual(restoredStore.range, .week)
    }
}

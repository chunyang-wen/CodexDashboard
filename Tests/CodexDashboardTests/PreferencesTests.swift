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
        XCTAssertEqual(defaults.string(forKey: DashboardPreferences.dashboardRangeKey), "Week")

        let restoredStore = DashboardStore(userHome: userHome, defaults: defaults)
        XCTAssertEqual(restoredStore.range, .week)
    }

    @MainActor
    func testMondayWeekCalendarIncludesSundayInTheCurrentWeek() {
        let suiteName = "PreferencesTests.WeekCalendar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = DashboardStore(defaults: defaults)
        let calendar = store.analyticsCalendar
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 8, day: 23, hour: 12))!
        let interval = calendar.dateInterval(of: .weekOfYear, for: sunday)!

        XCTAssertEqual(calendar.component(.weekday, from: interval.start), 2)
        XCTAssertTrue(interval.contains(sunday))
    }

    func testPersistedKeysAreCentralized() {
        XCTAssertEqual(
            DashboardPreferences.allPersistedKeys,
            Set([
                DashboardPreferences.migrationVersionKey,
                DashboardPreferences.codexDataPathKey,
                DashboardPreferences.metricsRefreshIntervalKey,
                DashboardPreferences.weekStartsMondayKey,
                DashboardPreferences.dashboardRangeKey,
                DashboardPreferences.overviewActivityMetricKey,
                DashboardPreferences.projectActivityMetricKey,
                DashboardPreferences.showMenuBarIconKey,
                DashboardPreferences.menuBarQuotaIconStyleKey,
                DashboardPreferences.showQuotaAlertMarkerKey,
                DashboardPreferences.quotaAlertUsedPercentKey,
                DashboardPreferences.menuBarUsageTrendMetricKey
            ])
        )
    }
}

@testable import CodexDashboard
import CodexMetricsCore
import Foundation
import XCTest

final class PreferencesTests: XCTestCase {
    @MainActor
    func testSubscriptionProviderDefaultsToDefaultAndPersistsSelection() {
        let suiteName = "PreferencesTests.SubscriptionProvider.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MenuBarStore(defaults: defaults)
        XCTAssertEqual(store.subscriptionProvider, .default)

        store.updateSubscriptionProvider(.cliProxyAPI)

        XCTAssertEqual(defaults.string(forKey: DashboardPreferences.subscriptionProviderKey), "cliProxyAPI")
        XCTAssertEqual(DashboardPreferences.subscriptionProvider(defaults: defaults), .cliProxyAPI)

        store.updateSubscriptionProvider(.sub2API)

        XCTAssertEqual(defaults.string(forKey: DashboardPreferences.subscriptionProviderKey), "sub2API")
        XCTAssertEqual(DashboardPreferences.subscriptionProvider(defaults: defaults), .sub2API)

        let restoredStore = MenuBarStore(defaults: defaults)
        XCTAssertEqual(restoredStore.subscriptionProvider, .sub2API)
    }

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

    @MainActor
    func testPeriodBucketsKeepDistinctSessionsAndMondayWeekBoundaries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 8, day: 23, hour: 12))!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 8, day: 24, hour: 12))!
        let rows = [
            DailyPeriodRow(
                day: sunday,
                usage: TokenUsage(input: 10),
                estimatedCost: 1,
                activeRuntime: 10,
                sessions: 2,
                sessionIDs: ["sunday-a", "shared"]
            ),
            DailyPeriodRow(
                day: monday,
                usage: TokenUsage(input: 20),
                estimatedCost: 2,
                activeRuntime: 20,
                sessions: 3,
                sessionIDs: ["monday-a", "monday-b", "shared"]
            )
        ]

        let days = DashboardStore.bucketPeriodsFromRows(rows, granularity: .day, calendar: calendar)
        XCTAssertEqual(days.map(\.sessions), [2, 3])

        let weeks = DashboardStore.bucketPeriodsFromRows(rows, granularity: .week, calendar: calendar)
        XCTAssertEqual(weeks.count, 2)
        XCTAssertEqual(weeks.map(\.sessions), [2, 3])
        XCTAssertEqual(calendar.component(.weekday, from: weeks[1].start), 2)
    }

    func testPersistedKeysAreCentralized() {
        XCTAssertEqual(
            DashboardPreferences.allPersistedKeys,
            Set([
                DashboardPreferences.migrationVersionKey,
                DashboardPreferences.codexDataPathKey,
                DashboardPreferences.subscriptionProviderKey,
                DashboardPreferences.cliProxyAPIEndpointKey,
                DashboardPreferences.sub2APIEndpointKey,
                DashboardPreferences.sub2APIAccountIDKey,
                DashboardPreferences.metricsRefreshIntervalKey,
                DashboardPreferences.weekStartsMondayKey,
                DashboardPreferences.dashboardRangeKey,
                DashboardPreferences.overviewActivityMetricKey,
                DashboardPreferences.projectActivityMetricKey,
                DashboardPreferences.showMenuBarIconKey,
                DashboardPreferences.menuBarQuotaIconStyleKey,
                DashboardPreferences.showQuotaAlertMarkerKey,
                DashboardPreferences.quotaAlertUsedPercentKey,
                DashboardPreferences.showQuotaFiveHourAlertMarkerKey,
                DashboardPreferences.quotaFiveHourAlertRemainingPercentKey,
                DashboardPreferences.showQuotaWeeklyAlertMarkerKey,
                DashboardPreferences.quotaWeeklyAlertRemainingPercentKey,
                DashboardPreferences.menuBarUsageTrendMetricKey
            ])
        )
    }
}

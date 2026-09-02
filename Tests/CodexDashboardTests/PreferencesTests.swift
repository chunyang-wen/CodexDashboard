@testable import CodexDashboard
import CodexMetricsCore
import Foundation
import XCTest

final class PreferencesTests: XCTestCase {
    func testProviderCredentialsAcceptOnlyPrintableASCII() {
        XCTAssertEqual(printableASCIICredential("Abc123!@#-_"), "Abc123!@#-_")
        XCTAssertEqual(printableASCIICredential("pass中文word\n\t"), "password")
    }

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

    func testMenuUsageTrendShowsThirtyDaysBackAndSevenDaysAhead() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let august31 = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 12))!

        let dates = menuUsageTrendDates(now: august31, calendar: calendar)

        XCTAssertEqual(dates.count, 38)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: dates.first!), DateComponents(year: 2026, month: 8, day: 1))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: dates[30]), DateComponents(year: 2026, month: 8, day: 31))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: dates.last!), DateComponents(year: 2026, month: 9, day: 7))
    }

    func testMenuUsageRollingIntervalsIncludeToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let september2 = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 12))!

        let last7Days = menuUsageRollingInterval(days: 7, now: september2, calendar: calendar)
        let last30Days = menuUsageRollingInterval(days: 30, now: september2, calendar: calendar)

        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: last7Days.start), DateComponents(year: 2026, month: 8, day: 27))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: last30Days.start), DateComponents(year: 2026, month: 8, day: 4))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: last7Days.end), DateComponents(year: 2026, month: 9, day: 2))
        XCTAssertEqual(last7Days.end, last30Days.end)
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
                DashboardPreferences.sub2APISubscriptionCacheKey,
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

    @MainActor
    func testSub2APICachedQuotaIsRestoredOnlyForTheSelectedAccount() {
        let suiteName = "PreferencesTests.Sub2APICache.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(DashboardSubscriptionProvider.sub2API.rawValue, forKey: DashboardPreferences.subscriptionProviderKey)
        defaults.set("42", forKey: DashboardPreferences.sub2APIAccountIDKey)
        let subscription = SubscriptionSnapshot(
            planType: "cached",
            limitID: "sub2api",
            limitName: nil,
            windows: [UsageQuotaWindow(usedPercent: 25, windowMinutes: 300, resetsAt: .now)],
            credits: nil,
            rateLimitReachedType: nil,
            observedAt: .now
        )

        DashboardPreferences.cacheSub2APISubscription(subscription, defaults: defaults)

        XCTAssertEqual(MenuBarStore(defaults: defaults).subscription, subscription)
        defaults.set("84", forKey: DashboardPreferences.sub2APIAccountIDKey)
        XCTAssertNil(MenuBarStore(defaults: defaults).subscription)
    }
}

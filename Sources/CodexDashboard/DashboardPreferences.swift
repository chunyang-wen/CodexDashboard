import Foundation

enum DashboardPreferences {
    static let suiteName = "com.chunyangwen.CodexDashboard.shared"
    static let migrationVersionKey = "dashboardPreferencesMigrationVersion"
    static let currentMigrationVersion = 3

    static let codexDataPathKey = "codexDataPath"
    static let metricsRefreshIntervalKey = "metricsRefreshInterval"
    static let weekStartsMondayKey = "weekStartsMonday"
    static let dashboardRangeKey = "dashboardRange"
    static let overviewActivityMetricKey = "overviewActivityMetric"
    static let projectActivityMetricKey = "projectActivityMetric"
    static let showMenuBarIconKey = "showMenuBarIcon"
    static let menuBarQuotaIconStyleKey = "menuBarQuotaIconStyle"
    static let showQuotaAlertMarkerKey = "showQuotaAlertMarker"
    static let quotaAlertUsedPercentKey = "quotaAlertUsedPercent"
    static let showQuotaFiveHourAlertMarkerKey = "showQuotaFiveHourAlertMarker"
    static let quotaFiveHourAlertRemainingPercentKey = "quotaFiveHourAlertRemainingPercent"
    static let showQuotaWeeklyAlertMarkerKey = "showQuotaWeeklyAlertMarker"
    static let quotaWeeklyAlertRemainingPercentKey = "quotaWeeklyAlertRemainingPercent"
    static let menuBarUsageTrendMetricKey = "menuBarUsageTrendMetric"

    static let migratedKeys = [
        codexDataPathKey,
        metricsRefreshIntervalKey,
        weekStartsMondayKey,
        dashboardRangeKey,
        overviewActivityMetricKey,
        projectActivityMetricKey,
        showMenuBarIconKey,
        menuBarQuotaIconStyleKey,
        showQuotaAlertMarkerKey,
        quotaAlertUsedPercentKey,
        showQuotaFiveHourAlertMarkerKey,
        quotaFiveHourAlertRemainingPercentKey,
        showQuotaWeeklyAlertMarkerKey,
        quotaWeeklyAlertRemainingPercentKey,
        menuBarUsageTrendMetricKey
    ]

    static let allPersistedKeys = Set([migrationVersionKey] + migratedKeys)

    static func sharedDefaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    @discardableResult
    static func migrateLegacyDefaults(
        legacy: UserDefaults = .standard,
        shared: UserDefaults = sharedDefaults()
    ) -> UserDefaults {
        guard shared.integer(forKey: migrationVersionKey) < currentMigrationVersion else {
            return shared
        }

        for key in migratedKeys where shared.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) {
                shared.set(value, forKey: key)
            }
        }

        let legacyEnabled = (shared.object(forKey: showQuotaAlertMarkerKey) as? NSNumber)?.boolValue
            ?? (legacy.object(forKey: showQuotaAlertMarkerKey) as? NSNumber)?.boolValue
        let legacyThreshold = (shared.object(forKey: quotaAlertUsedPercentKey) as? NSNumber)?.doubleValue
            ?? (legacy.object(forKey: quotaAlertUsedPercentKey) as? NSNumber)?.doubleValue
        if let legacyEnabled {
            if shared.object(forKey: showQuotaFiveHourAlertMarkerKey) == nil {
                shared.set(legacyEnabled, forKey: showQuotaFiveHourAlertMarkerKey)
            }
            if shared.object(forKey: showQuotaWeeklyAlertMarkerKey) == nil {
                shared.set(legacyEnabled, forKey: showQuotaWeeklyAlertMarkerKey)
            }
        }
        if let legacyThreshold {
            if shared.object(forKey: quotaFiveHourAlertRemainingPercentKey) == nil {
                shared.set(legacyThreshold, forKey: quotaFiveHourAlertRemainingPercentKey)
            }
            if shared.object(forKey: quotaWeeklyAlertRemainingPercentKey) == nil {
                shared.set(legacyThreshold, forKey: quotaWeeklyAlertRemainingPercentKey)
            }
        }
        shared.set(currentMigrationVersion, forKey: migrationVersionKey)
        return shared
    }
}

struct DashboardSettingsUpdate: Equatable, Sendable {
    static let command = "settingsChanged"

    let codexDataPath: String?
    let refreshInterval: TimeInterval?
    let weekStartsMonday: Bool?

    init?(
        userInfo: [AnyHashable: Any],
        expectedToken: String?,
        expectedHostPID: Int32?,
        expectedHelperPID: Int32,
        expectedGeneration: UInt64
    ) {
        guard
            userInfo["command"] as? String == Self.command,
            let token = userInfo["launchToken"] as? String,
            token == expectedToken,
            let hostPID = (userInfo["hostPID"] as? NSNumber)?.int32Value,
            hostPID == expectedHostPID,
            let helperPID = (userInfo["processID"] as? NSNumber)?.int32Value,
            helperPID == expectedHelperPID,
            let generation = (userInfo["generation"] as? NSNumber)?.uint64Value,
            generation == expectedGeneration
        else { return nil }

        codexDataPath = userInfo[DashboardPreferences.codexDataPathKey] as? String
        refreshInterval = (userInfo[DashboardPreferences.metricsRefreshIntervalKey] as? NSNumber)?.doubleValue
        weekStartsMonday = (userInfo[DashboardPreferences.weekStartsMondayKey] as? NSNumber)?.boolValue
    }
}

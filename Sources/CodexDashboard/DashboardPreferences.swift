import Foundation

enum DashboardPreferences {
    static let suiteName = "com.chunyangwen.CodexDashboard.shared"
    static let migrationVersionKey = "dashboardPreferencesMigrationVersion"
    static let currentMigrationVersion = 2

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

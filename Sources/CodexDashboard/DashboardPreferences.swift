import Foundation
import CodexMetricsCore
import Security

enum DashboardPreferences {
    static let suiteName = "com.chunyangwen.CodexDashboard.shared"
    static let migrationVersionKey = "dashboardPreferencesMigrationVersion"
    static let currentMigrationVersion = 5

    static let codexDataPathKey = "codexDataPath"
    static let subscriptionProviderKey = "subscriptionProvider"
    static let cliProxyAPIEndpointKey = "cliProxyAPIEndpoint"
    static let sub2APIEndpointKey = "sub2APIEndpoint"
    static let sub2APIAccountIDKey = "sub2APIAccountID"
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
        subscriptionProviderKey,
        cliProxyAPIEndpointKey,
        sub2APIEndpointKey,
        sub2APIAccountIDKey,
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

    static func subscriptionProvider(defaults: UserDefaults = sharedDefaults()) -> DashboardSubscriptionProvider {
        DashboardSubscriptionProvider(rawValue: defaults.string(forKey: subscriptionProviderKey) ?? "") ?? .default
    }

    static func cliProxyAPIConfiguration(defaults: UserDefaults = sharedDefaults()) -> CLIProxyAPIConfiguration? {
        guard let endpoint = defaults.string(forKey: cliProxyAPIEndpointKey),
              let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = DashboardKeychain.readManagementKey(),
              !key.isEmpty else { return nil }
        return CLIProxyAPIConfiguration(baseURL: url, managementKey: key)
    }

    static func sub2APIConfiguration(defaults: UserDefaults = sharedDefaults()) -> Sub2APIConfiguration? {
        guard let endpoint = defaults.string(forKey: sub2APIEndpointKey),
              let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let token = DashboardKeychain.readSub2APIAdminToken(),
              !token.isEmpty,
              let accountID = Int64(defaults.string(forKey: sub2APIAccountIDKey) ?? ""),
              accountID > 0 else { return nil }
        return Sub2APIConfiguration(baseURL: url, adminToken: token, accountID: accountID)
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

enum DashboardSubscriptionProvider: String, CaseIterable, Identifiable {
    case `default` = "default"
    case cliProxyAPI = "cliProxyAPI"
    case sub2API = "sub2API"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .default: "Default"
        case .cliProxyAPI: "CLIProxyAPI"
        case .sub2API: "Wei-Shaw/sub2api"
        }
    }
}

enum DashboardKeychain {
    private static let service = "com.chunyangwen.CodexDashboard"
    private static let account = "cliProxyAPIManagementKey"
    private static let sub2APIAdminTokenAccount = "sub2APIAdminAccessToken"

    static func readManagementKey() -> String? {
        read(account: account)
    }

    static func readSub2APIAdminToken() -> String? {
        read(account: sub2APIAdminTokenAccount)
    }

    private static func read(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func saveManagementKey(_ key: String) -> Bool {
        save(key, account: account)
    }

    @discardableResult
    static func saveSub2APIAdminToken(_ token: String) -> Bool {
        save(token, account: sub2APIAdminTokenAccount)
    }

    @discardableResult
    private static func save(_ key: String, account: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        if trimmed.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        let data = Data(trimmed.utf8)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var addQuery = query
        addQuery[kSecValueData] = data
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
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

import Foundation

public struct CodexAccountSnapshot: Codable, Hashable, Sendable {
    public let email: String
    public let name: String?
    public let planType: String?

    public init(email: String, name: String?, planType: String?) {
        self.email = email
        self.name = name
        self.planType = planType
    }
}

public enum CodexPlanDisplay {
    public static func name(for planType: String) -> String {
        let normalized = planType.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty
            || normalized.caseInsensitiveCompare("unknown") == .orderedSame
            || normalized.caseInsensitiveCompare("api") == .orderedSame {
            return "API"
        }
        return normalized.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

public enum CodexAccountReader {
    /// Reads display-only identity claims from the locally stored ID token. The token
    /// is never returned, logged, persisted, or sent over the network.
    public static func read(from codexHome: URL) -> CodexAccountSnapshot? {
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["id_token"] as? String else { return nil }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count > 1,
              let payload = decodeBase64URL(String(segments[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let email = claims["email"] as? String, !email.isEmpty else { return nil }
        let authClaims = claims["https://api.openai.com/auth"] as? [String: Any]
        return CodexAccountSnapshot(
            email: email,
            name: claims["name"] as? String,
            planType: authClaims?["chatgpt_plan_type"] as? String
        )
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized.append(String(repeating: "=", count: (4 - normalized.count % 4) % 4))
        return Data(base64Encoded: normalized)
    }
}

public struct UsageQuotaWindow: Identifiable, Codable, Hashable, Sendable {
    public let usedPercent: Double
    public let windowMinutes: Int
    public let resetsAt: Date

    public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    public var id: String { "\(windowMinutes)-\(resetsAt.timeIntervalSince1970)" }
    public var remainingPercent: Double { max(0, 100 - usedPercent) }
    public var displayName: String {
        switch windowMinutes {
        case 300: return "5-hour quota"
        case 10_080: return "Weekly quota"
        case 43_200: return "Monthly quota"
        default:
            if windowMinutes.isMultiple(of: 1_440) { return "\(windowMinutes / 1_440)-day quota" }
            if windowMinutes.isMultiple(of: 60) { return "\(windowMinutes / 60)-hour quota" }
            return "\(windowMinutes)-minute quota"
        }
    }
}

public struct SubscriptionCredits: Codable, Hashable, Sendable {
    public let hasCredits: Bool
    public let unlimited: Bool
    public let balance: String?

    public init(hasCredits: Bool, unlimited: Bool, balance: String?) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }
}

public struct SubscriptionSnapshot: Codable, Hashable, Sendable {
    public let planType: String
    public let limitID: String
    public let limitName: String?
    public let windows: [UsageQuotaWindow]
    public let credits: SubscriptionCredits?
    public let rateLimitReachedType: String?
    public let observedAt: Date

    public init(
        planType: String,
        limitID: String,
        limitName: String?,
        windows: [UsageQuotaWindow],
        credits: SubscriptionCredits?,
        rateLimitReachedType: String?,
        observedAt: Date
    ) {
        self.planType = planType
        self.limitID = limitID
        self.limitName = limitName
        self.windows = windows
        self.credits = credits
        self.rateLimitReachedType = rateLimitReachedType
        self.observedAt = observedAt
    }

    public var displayPlan: String {
        CodexPlanDisplay.name(for: planType)
    }

    /// Some providers, including OpenRouter, emit a `rate_limits` envelope with
    /// every subscription field set to null. It is a telemetry placeholder, not
    /// an account quota snapshot, and must not replace the last real snapshot.
    public var isUsable: Bool {
        !windows.isEmpty
            || credits != nil
            || !planType.isEmpty && planType != "unknown"
            || limitName.map { !$0.isEmpty } == true
            || rateLimitReachedType != nil
    }

    public func hasSameQuota(as other: SubscriptionSnapshot) -> Bool {
        planType == other.planType
            && limitID == other.limitID
            && limitName == other.limitName
            && windows == other.windows
            && credits == other.credits
            && rateLimitReachedType == other.rateLimitReachedType
    }
}

public enum SubscriptionReader {
    /// Returns already-parsed quota data without opening any rollout files.
    public static func latestCached(from sessions: [SessionMetric]) -> SubscriptionSnapshot? {
        sessions.compactMap(\.subscription).filter(\.isUsable).max { $0.observedAt < $1.observedAt }
    }

    /// Reads only the tail of recent rollouts. Quota snapshots are emitted by Codex with
    /// token-count events, so this does not require credentials or a full history scan.
    public static func latest(from sessions: [SessionMetric]) -> SubscriptionSnapshot? {
        sessions.prefix(20)
            .lazy
            .filter { !$0.rolloutPath.isEmpty }
            .compactMap { latest(in: $0.rolloutPath) }
            .max { $0.observedAt < $1.observedAt }
    }

    /// Fetches the live account quota used by Codex itself. Rollout files only
    /// receive rate-limit events during activity, so reading this endpoint is
    /// necessary to observe a reset while the user is idle.
    public static func live(from codexHome: URL) async -> SubscriptionSnapshot? {
        guard let credentials = credentials(from: codexHome),
              let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Dashboard", forHTTPHeaderField: "originator")
        if let accountID = credentials.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return snapshot(fromUsage: object, observedAt: .now)
        } catch {
            return nil
        }
    }

    static func latest(in path: String, maximumTailBytes: UInt64 = 8 * 1_024 * 1_024) -> SubscriptionSnapshot? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > maximumTailBytes ? end - maximumTailBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }

        let lines = data.split(separator: 0x0A)
        for line in lines.reversed() {
            let lineData = Data(line)
            guard lineData.range(of: Data(#""rate_limits":"#.utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            if let snapshot = snapshot(from: limits, timestamp: object["timestamp"] as? String) {
                return snapshot
            }
        }
        return nil
    }

    static func snapshot(from value: [String: Any], timestamp: String?) -> SubscriptionSnapshot? {
        snapshot(from: value, observedAt: parseDate(timestamp) ?? .now)
    }

    static func snapshot(from value: [String: Any], observedAt: Date) -> SubscriptionSnapshot? {
        let windows = ["primary", "secondary", "individual_limit"].compactMap { key -> UsageQuotaWindow? in
            guard let window = value[key] as? [String: Any],
                  let used = number(window["used_percent"]),
                  let minutes = integer(window["window_minutes"]),
                  let reset = number(window["resets_at"]) else { return nil }
            return UsageQuotaWindow(usedPercent: used, windowMinutes: minutes, resetsAt: Date(timeIntervalSince1970: reset))
        }
        .sorted { $0.windowMinutes < $1.windowMinutes }

        let credits = (value["credits"] as? [String: Any]).map {
            SubscriptionCredits(
                hasCredits: ($0["has_credits"] as? Bool) ?? false,
                unlimited: ($0["unlimited"] as? Bool) ?? false,
                balance: $0["balance"] as? String
            )
        }
        // A custom provider may omit plan_type while still reporting useful
        // quota windows. Keep that snapshot and label it API. A completely
        // empty rate_limits envelope is only a provider placeholder, though;
        // do not turn it into a durable fake subscription snapshot.
        let hasReportedQuota = !windows.isEmpty
            || credits != nil
            || (value["limit_name"] as? String)?.isEmpty == false
            || value["rate_limit_reached_type"] as? String != nil
        let reportedPlanType = (value["plan_type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMeaningfulPlan = reportedPlanType.map {
            !$0.isEmpty && $0.caseInsensitiveCompare("unknown") != .orderedSame
        } ?? false
        guard hasReportedQuota || hasMeaningfulPlan else { return nil }
        let displayPlanType = hasMeaningfulPlan ? reportedPlanType! : "API"

        let snapshot = SubscriptionSnapshot(
            planType: displayPlanType,
            limitID: value["limit_id"] as? String ?? "codex",
            limitName: value["limit_name"] as? String,
            windows: windows,
            credits: credits,
            rateLimitReachedType: value["rate_limit_reached_type"] as? String,
            observedAt: observedAt
        )
        return snapshot.isUsable ? snapshot : nil
    }

    static func snapshot(fromUsage value: [String: Any], observedAt: Date) -> SubscriptionSnapshot? {
        let root = value["rate_limit"] as? [String: Any]
            ?? value["rate_limits"] as? [String: Any]
        guard let root else { return nil }

        var normalized = [String: Any]()
        for (sourceKey, targetKey) in [("primary_window", "primary"), ("secondary_window", "secondary")] {
            guard let rawWindow = root[sourceKey] as? [String: Any],
                  let usedPercent = number(rawWindow["used_percent"] ?? rawWindow["usedPercent"]),
                  let windowSeconds = number(rawWindow["limit_window_seconds"] ?? rawWindow["window_duration_mins"]) else {
                continue
            }
            let windowMinutes = rawWindow["limit_window_seconds"] != nil
                ? Int(windowSeconds / 60)
                : Int(windowSeconds)
            guard windowMinutes > 0,
                  let resetsAt = number(rawWindow["reset_at"] ?? rawWindow["resets_at"]) else { continue }
            normalized[targetKey] = [
                "used_percent": usedPercent,
                "window_minutes": windowMinutes,
                "resets_at": resetsAt
            ]
        }

        if let credits = value["credits"] as? [String: Any] {
            normalized["credits"] = credits
        }
        if let limitName = value["limit_name"] as? String {
            normalized["limit_name"] = limitName
        }
        if let reached = value["rate_limit_reached_type"] as? String {
            normalized["rate_limit_reached_type"] = reached
        } else if let reached = value["rate_limit_reached_type"] as? [String: Any],
                  let type = reached["type"] as? String {
            normalized["rate_limit_reached_type"] = type
        }
        normalized["plan_type"] = value["plan_type"] as? String ?? "API"
        return snapshot(from: normalized, observedAt: observedAt)
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        number(value).map(Int.init)
    }

    private static func credentials(from codexHome: URL) -> (accessToken: String, accountID: String?)? {
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else { return nil }
        return (accessToken, tokens["account_id"] as? String)
    }
}

public struct CLIProxyAPIConfiguration: Equatable, Sendable {
    public let baseURL: URL
    public let managementKey: String

    public init(baseURL: URL, managementKey: String) {
        self.baseURL = baseURL
        self.managementKey = managementKey
    }
}

public struct ProviderLiveSnapshot: Sendable {
    public let subscription: SubscriptionSnapshot?
    public let account: CodexAccountSnapshot?
    public let usageCosts: [Sub2APIUsageCost]

    public init(
        subscription: SubscriptionSnapshot?,
        account: CodexAccountSnapshot?,
        usageCosts: [Sub2APIUsageCost] = []
    ) {
        self.subscription = subscription
        self.account = account
        self.usageCosts = usageCosts
    }
}

public typealias CLIProxyAPILiveSnapshot = ProviderLiveSnapshot

public struct CLIProxyAPIValidationResult: Sendable {
    public let isValid: Bool
    public let message: String

    public init(isValid: Bool, message: String) {
        self.isValid = isValid
        self.message = message
    }
}

public enum CLIProxyAPIReader {
    private static let quotaURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let bankedResetURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    /// Asks CLIProxyAPI to use one of its own Codex OAuth credentials. The
    /// management key authorizes only the local management request; the OAuth
    /// token never leaves CLIProxyAPI and is never returned here.
    public static func live(using configuration: CLIProxyAPIConfiguration) async -> SubscriptionSnapshot? {
        await liveData(using: configuration)?.subscription
    }

    public static func liveData(using configuration: CLIProxyAPIConfiguration) async -> ProviderLiveSnapshot? {
        let managementKey = configuration.managementKey
        guard !managementKey.isEmpty else { return nil }

        do {
            let codexAuth = try await activeCodexAuth(using: configuration)
            let quota = try await proxyGET(quotaURL, auth: codexAuth, using: configuration)
            return ProviderLiveSnapshot(
                subscription: SubscriptionReader.snapshot(fromUsage: quota, observedAt: .now),
                account: account(from: codexAuth, usage: quota)
            )
        } catch {
            return nil
        }
    }

    public static func latestBankedReset(using configuration: CLIProxyAPIConfiguration) async -> BankedResetSnapshot? {
        guard !configuration.managementKey.isEmpty else { return nil }
        do {
            let codexAuth = try await activeCodexAuth(using: configuration)
            let object = try await proxyGET(bankedResetURL, auth: codexAuth, using: configuration)
            return BankedResetReader.snapshot(from: object)
        } catch {
            return nil
        }
    }

    public static func validate(using configuration: CLIProxyAPIConfiguration) async -> CLIProxyAPIValidationResult {
        guard !configuration.managementKey.isEmpty else {
            return CLIProxyAPIValidationResult(
                isValid: false,
                message: "Enter the CLIProxyAPI management key."
            )
        }
        do {
            let codexAuth = try await activeCodexAuth(using: configuration)
            _ = try await proxyGET(quotaURL, auth: codexAuth, using: configuration)
            let account = (codexAuth["email"] as? String) ?? "active Codex account"
            return CLIProxyAPIValidationResult(
                isValid: true,
                message: "Connected successfully (\(account))."
            )
        } catch {
            return CLIProxyAPIValidationResult(
                isValid: false,
                message: "Validation failed. Check the endpoint, management key, and active Codex auth."
            )
        }
    }

    private static func account(from auth: [String: Any], usage: [String: Any]) -> CodexAccountSnapshot? {
        let email = (auth["email"] as? String) ?? (usage["email"] as? String) ?? ""
        guard !email.isEmpty else { return nil }
        return CodexAccountSnapshot(
            email: email,
            name: auth["name"] as? String,
            planType: usage["plan_type"] as? String
        )
    }

    private static func activeCodexAuth(using configuration: CLIProxyAPIConfiguration) async throws -> [String: Any] {
        let authFiles = try await request(
            URLRequest(url: configuration.baseURL.appendingPathComponent("v0/management/auth-files")),
            managementKey: configuration.managementKey
        )
        guard let files = authFiles["files"] as? [[String: Any]],
              let codexAuth = files.first(where: {
                  let provider = (($0["provider"] as? String) ?? ($0["type"] as? String) ?? "")
                      .trimmingCharacters(in: .whitespacesAndNewlines)
                      .lowercased()
                  let disabled = ($0["disabled"] as? Bool) ?? false
                  let unavailable = ($0["unavailable"] as? Bool) ?? false
                  return provider == "codex" && !disabled && !unavailable
              }),
              let authIndex = codexAuth["auth_index"] as? String,
              !authIndex.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        return codexAuth
    }

    private static func proxyGET(
        _ url: URL,
        auth: [String: Any],
        using configuration: CLIProxyAPIConfiguration
    ) async throws -> [String: Any] {
        guard let authIndex = auth["auth_index"] as? String, !authIndex.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        var headers = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "User-Agent": "codex_cli_rs/0.76.0 (CodexDashboard)",
            "OpenAI-Beta": "codex-1",
            "Originator": "Codex Dashboard"
        ]
        if let idToken = auth["id_token"] as? [String: Any],
           let accountID = idToken["chatgpt_account_id"] as? String,
           !accountID.isEmpty {
            headers["Chatgpt-Account-Id"] = accountID
        }

        let body: [String: Any] = [
            "auth_index": authIndex,
            "method": "GET",
            "url": url.absoluteString,
            "header": headers
        ]
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("v0/management/api-call"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let response = try await data(for: request, managementKey: configuration.managementKey)
        guard let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let statusCode = (envelope["status_code"] as? NSNumber)?.intValue,
              (200..<300).contains(statusCode),
              let responseBody = envelope["body"] as? String,
              let object = try JSONSerialization.jsonObject(with: Data(responseBody.utf8)) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return object
    }

    private static func request(_ request: URLRequest, managementKey: String) async throws -> [String: Any] {
        let data = try await data(for: request, managementKey: managementKey)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return object
    }

    private static func data(for request: URLRequest, managementKey: String) async throws -> Data {
        var request = request
        request.timeoutInterval = 15
        request.setValue(managementKey, forHTTPHeaderField: "X-Management-Key")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

public struct Sub2APIConfiguration: Equatable, Sendable {
    public let baseURL: URL
    public let adminToken: String
    public let accountID: Int64

    public init(baseURL: URL, adminToken: String, accountID: Int64) {
        self.baseURL = baseURL
        self.adminToken = adminToken
        self.accountID = accountID
    }
}

public struct Sub2APIValidationResult: Sendable {
    public let isValid: Bool
    public let message: String
    public let subscription: SubscriptionSnapshot?

    public init(isValid: Bool, message: String, subscription: SubscriptionSnapshot? = nil) {
        self.isValid = isValid
        self.message = message
        self.subscription = subscription
    }
}

public struct Sub2APIAdminAccount: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let name: String
    public let platform: String

    public init(id: Int64, name: String, platform: String) {
        self.id = id
        self.name = name
        self.platform = platform
    }
}

public struct Sub2APISignInResult: Sendable {
    public let isValid: Bool
    public let message: String
    public let accessToken: String?
    public let refreshToken: String?
    public let accounts: [Sub2APIAdminAccount]

    public init(
        isValid: Bool,
        message: String,
        accessToken: String? = nil,
        refreshToken: String? = nil,
        accounts: [Sub2APIAdminAccount] = []
    ) {
        self.isValid = isValid
        self.message = message
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accounts = accounts
    }
}

public struct Sub2APISessionTokens: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresIn: TimeInterval

    public init(accessToken: String, refreshToken: String, expiresIn: TimeInterval) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
    }
}

public struct Sub2APIUsageCost: Equatable, Sendable {
    public let id: Int64
    public let sessionID: String
    public let createdAt: Date
    public let totalCost: Decimal
    public let serviceTier: String?
    public let reasoningEffort: String?

    public init(
        id: Int64,
        sessionID: String,
        createdAt: Date,
        totalCost: Decimal,
        serviceTier: String?,
        reasoningEffort: String?
    ) {
        self.id = id
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.totalCost = totalCost
        self.serviceTier = serviceTier
        self.reasoningEffort = reasoningEffort
    }
}

public enum Sub2APIReader {
    public static func live(using configuration: Sub2APIConfiguration) async -> SubscriptionSnapshot? {
        await liveData(using: configuration)?.subscription
    }

    public static func liveData(using configuration: Sub2APIConfiguration) async -> ProviderLiveSnapshot? {
        guard !configuration.adminToken.isEmpty, configuration.accountID > 0 else { return nil }
        async let quotaRequest = try? quota(using: configuration)
        async let usageRequest = try? usage(using: configuration)
        async let usageCostsRequest = try? usageCosts(using: configuration, on: .now)
        let quota = await quotaRequest
        let usage = await usageRequest
        let usageCosts = await usageCostsRequest ?? []
        let observedAt = Date.now
        let subscription = usage.flatMap {
            snapshot(fromAdminUsage: $0, planType: quota?["plan_type"] as? String, observedAt: observedAt)
        } ?? quota.flatMap { snapshot(fromQuota: $0, observedAt: observedAt) }
        guard subscription != nil || quota != nil else { return nil }
        return ProviderLiveSnapshot(
            subscription: subscription,
            account: quota.flatMap { account(from: $0) },
            usageCosts: usageCosts
        )
    }

    public static func latestBankedReset(using configuration: Sub2APIConfiguration) async -> BankedResetSnapshot? {
        guard !configuration.adminToken.isEmpty, configuration.accountID > 0 else { return nil }
        guard let quota = try? await quota(using: configuration) else { return nil }
        return bankedResetSnapshot(fromQuota: quota, observedAt: .now)
    }

    public static func validate(using configuration: Sub2APIConfiguration) async -> Sub2APIValidationResult {
        guard !configuration.adminToken.isEmpty else {
            return Sub2APIValidationResult(isValid: false, message: "Enter the sub2api admin access token.")
        }
        guard configuration.accountID > 0 else {
            return Sub2APIValidationResult(isValid: false, message: "Enter a valid upstream account ID.")
        }
        do {
            let quota = try await quota(using: configuration)
            let subscription = snapshot(fromQuota: quota, observedAt: .now)
            let plan = (quota["plan_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (quota["planName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let suffix = plan.map { " (\($0))" } ?? ""
            let email = (quota["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let identity = email.map { " (\($0))" } ?? suffix
            return Sub2APIValidationResult(
                isValid: true,
                message: "Connected successfully\(identity).",
                subscription: subscription
            )
        } catch {
            return Sub2APIValidationResult(
                isValid: false,
                message: "Validation failed. Check the endpoint, admin access token, and upstream account ID."
            )
        }
    }

    public static func signIn(
        email: String,
        password: String,
        baseURL: URL
    ) async -> Sub2APISignInResult {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty else {
            return Sub2APISignInResult(isValid: false, message: "Enter the admin email and password.")
        }
        do {
            let login = try await login(email: email, password: password, baseURL: baseURL)
            if (login["requires_2fa"] as? Bool) == true {
                return Sub2APISignInResult(isValid: false, message: "This admin account requires two-factor authentication.")
            }
            guard let accessToken = login["access_token"] as? String, !accessToken.isEmpty,
                  let refreshToken = login["refresh_token"] as? String, !refreshToken.isEmpty else {
                throw URLError(.cannotParseResponse)
            }
            let accounts = try await fetchAccounts(baseURL: baseURL, adminToken: accessToken)
            return Sub2APISignInResult(
                isValid: true,
                message: accounts.isEmpty ? "Signed in, but no upstream accounts were found." : "Signed in successfully. Select an upstream account.",
                accessToken: accessToken,
                refreshToken: refreshToken,
                accounts: accounts
            )
        } catch {
            return Sub2APISignInResult(
                isValid: false,
                message: "Sign-in failed. Check the endpoint, admin email, and password."
            )
        }
    }

    public static func accounts(baseURL: URL, adminToken: String) async -> [Sub2APIAdminAccount] {
        (try? await fetchAccounts(baseURL: baseURL, adminToken: adminToken)) ?? []
    }

    public static func refreshSession(refreshToken: String, baseURL: URL) async throws -> Sub2APISessionTokens {
        var request = URLRequest(url: apiURL(for: baseURL, path: ["auth", "refresh"]))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Codex Dashboard", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        let object = try await responseObject(for: request)
        return try sessionTokens(from: object)
    }

    static func sessionTokens(from object: [String: Any]) throws -> Sub2APISessionTokens {
        guard let accessToken = object["access_token"] as? String, !accessToken.isEmpty,
              let nextRefreshToken = object["refresh_token"] as? String, !nextRefreshToken.isEmpty,
              let expiresIn = number(object["expires_in"]), expiresIn > 0 else {
            throw URLError(.cannotParseResponse)
        }
        return Sub2APISessionTokens(
            accessToken: accessToken,
            refreshToken: nextRefreshToken,
            expiresIn: expiresIn
        )
    }

    public static func accessTokenNeedsRefresh(
        _ token: String,
        now: Date = .now,
        leeway: TimeInterval = 300
    ) -> Bool {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return false }
        var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload.append(String(repeating: "=", count: (4 - payload.count % 4) % 4))
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiresAt = number(object["exp"]) else { return false }
        return expiresAt <= now.timeIntervalSince1970 + leeway
    }

    public static func snapshot(fromQuota value: [String: Any], observedAt: Date) -> SubscriptionSnapshot? {
        let quota = value["quota"] as? [String: Any] ?? value
        return SubscriptionReader.snapshot(fromUsage: quota, observedAt: observedAt)
    }

    public static func snapshot(
        fromAdminUsage value: [String: Any],
        planType: String? = nil,
        observedAt: Date
    ) -> SubscriptionSnapshot? {
        let windows: [(key: String, minutes: Int)] = [
            ("five_hour", 300),
            ("seven_day", 10_080)
        ]
        let parsedWindows = windows.compactMap { definition -> UsageQuotaWindow? in
            guard let rawWindow = value[definition.key] as? [String: Any],
                  let utilization = number(rawWindow["utilization"]),
                  let reset = date(rawWindow["resets_at"]) else { return nil }
            return UsageQuotaWindow(
                usedPercent: min(100, max(0, utilization)),
                windowMinutes: definition.minutes,
                resetsAt: reset
            )
        }
        guard !parsedWindows.isEmpty else { return nil }
        return SubscriptionSnapshot(
            planType: planType ?? "Sub2API",
            limitID: "sub2api",
            limitName: nil,
            windows: parsedWindows.sorted { $0.windowMinutes < $1.windowMinutes },
            credits: nil,
            rateLimitReachedType: nil,
            observedAt: observedAt
        )
    }

    public static func bankedResetSnapshot(
        fromQuota value: [String: Any],
        observedAt: Date
    ) -> BankedResetSnapshot? {
        let quota = value["quota"] as? [String: Any] ?? value
        guard let resetCredits = quota["rate_limit_reset_credits"] as? [String: Any],
              let availableCount = integer(resetCredits["available_count"] ?? resetCredits["availableCount"]),
              availableCount >= 0 else { return nil }

        let credits = (resetCredits["credits"] as? [[String: Any]])?.enumerated().compactMap { index, value in
            BankedResetCredit(
                id: value["id"] as? String ?? "sub2api-reset-credit-\(index)",
                status: value["status"] as? String ?? "available",
                grantedAt: date(value["granted_at"] ?? value["grantedAt"]) ?? observedAt,
                expiresAt: date(value["expires_at"] ?? value["expiresAt"]),
                title: value["title"] as? String,
                description: value["description"] as? String
            )
        }
        return BankedResetSnapshot(
            availableCount: availableCount,
            credits: resetCredits["credits"] == nil ? nil : credits,
            observedAt: observedAt
        )
    }

    private static func account(from quota: [String: Any]) -> CodexAccountSnapshot? {
        guard let email = quota["email"] as? String, !email.isEmpty else { return nil }
        return CodexAccountSnapshot(
            email: email,
            name: nil,
            planType: quota["plan_type"] as? String
        )
    }

    public static func snapshot(fromUsage value: [String: Any], observedAt: Date) -> SubscriptionSnapshot? {
        guard (value["isValid"] as? Bool) != false else { return nil }

        var windows = rateLimitWindows(from: value["rate_limits"] as? [[String: Any]])
        let planName = (value["planName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = (value["mode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        if mode == "unrestricted", let subscription = value["subscription"] as? [String: Any] {
            windows.append(contentsOf: subscriptionWindows(from: subscription, observedAt: observedAt))
        }

        let quota = value["quota"] as? [String: Any]
        let balance = number(value["remaining"] ?? value["balance"] ?? quota?["remaining"])
        let credits: SubscriptionCredits? = balance.map {
            SubscriptionCredits(
                hasCredits: $0 > 0,
                unlimited: $0 < 0,
                balance: $0 < 0 ? nil : decimalString($0)
            )
        }
        guard !windows.isEmpty || credits != nil || planName?.isEmpty == false else { return nil }

        let planType: String
        switch mode {
        case "quota_limited": planType = planName ?? "API key quota"
        case "unrestricted": planType = planName ?? "Sub2API"
        default: planType = planName ?? "Sub2API"
        }

        let limitName = planName?.isEmpty == false ? planName : nil
        return SubscriptionSnapshot(
            planType: planType,
            limitID: "sub2api",
            limitName: limitName,
            windows: windows.sorted { $0.windowMinutes < $1.windowMinutes },
            credits: credits,
            rateLimitReachedType: nil,
            observedAt: observedAt
        )
    }

    static func usageCosts(from value: [String: Any]) -> [Sub2APIUsageCost] {
        let items = value["items"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let idValue = number(item["id"]), idValue > 0,
                  let sessionID = (item["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sessionID.isEmpty,
                  let createdAt = date(item["created_at"]),
                  let costValue = number(item["total_cost"]), costValue >= 0 else { return nil }
            let effectiveEffort = (item["upstream_reasoning_effort"] as? String)
                ?? (item["reasoning_effort"] as? String)
            return Sub2APIUsageCost(
                id: Int64(idValue),
                sessionID: sessionID,
                createdAt: createdAt,
                totalCost: Decimal(costValue),
                serviceTier: item["service_tier"] as? String,
                reasoningEffort: effectiveEffort
            )
        }
    }

    private static func quota(using configuration: Sub2APIConfiguration) async throws -> [String: Any] {
        var request = URLRequest(url: quotaURL(for: configuration.baseURL, accountID: configuration.accountID))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(configuration.adminToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Codex Dashboard", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        if let code = root["code"] as? NSNumber, code.intValue != 0 {
            throw URLError(.badServerResponse)
        }
        return root["data"] as? [String: Any] ?? root
    }

    private static func usage(using configuration: Sub2APIConfiguration) async throws -> [String: Any] {
        var components = URLComponents(url: usageURL(for: configuration.baseURL, accountID: configuration.accountID), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "source", value: "active"),
            URLQueryItem(name: "force", value: "true")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(configuration.adminToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Codex Dashboard", forHTTPHeaderField: "User-Agent")
        return try await responseObject(for: request)
    }

    public static func historicalUsageCosts(
        using configuration: Sub2APIConfiguration,
        since startDate: Date,
        before endDate: Date = .now,
        calendar: Calendar = .current
    ) async throws -> [Sub2APIUsageCost] {
        try await usageCosts(
            using: configuration,
            since: startDate,
            before: endDate,
            calendar: calendar,
            maximumPages: 100
        )
    }

    static func usageCosts(
        using configuration: Sub2APIConfiguration,
        on day: Date,
        calendar: Calendar = .current
    ) async throws -> [Sub2APIUsageCost] {
        try await usageCosts(
            using: configuration,
            since: day,
            before: day,
            calendar: calendar,
            maximumPages: 10
        )
    }

    private static func usageCosts(
        using configuration: Sub2APIConfiguration,
        since startDate: Date,
        before endDate: Date,
        calendar: Calendar = .current,
        maximumPages: Int = 10
    ) async throws -> [Sub2APIUsageCost] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let start = formatter.string(from: min(startDate, endDate))
        let end = formatter.string(from: max(startDate, endDate))
        let pageSize = 1_000
        var records: [Sub2APIUsageCost] = []
        var receivedItems = 0

        for page in 1...maximumPages {
            if Task.isCancelled {
                throw CancellationError()
            }
            var components = URLComponents(
                url: apiURL(for: configuration.baseURL, path: ["admin", "usage"]),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                URLQueryItem(name: "account_id", value: String(configuration.accountID)),
                URLQueryItem(name: "start_date", value: start),
                URLQueryItem(name: "end_date", value: end),
                URLQueryItem(name: "timezone", value: calendar.timeZone.identifier),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page_size", value: String(pageSize)),
                URLQueryItem(name: "exact_total", value: "true")
            ]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            request.setValue("Bearer \(configuration.adminToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Codex Dashboard", forHTTPHeaderField: "User-Agent")
            let object = try await responseObject(for: request)
            let pageRecords = usageCosts(from: object)
            records.append(contentsOf: pageRecords)
            let itemCount = (object["items"] as? [[String: Any]])?.count ?? 0
            receivedItems += itemCount
            let total = Int(number(object["total"]) ?? Double(receivedItems))
            if receivedItems >= total { return records }
            if itemCount == 0 { return records }
        }
        // A partial fetch would understate cost, so leave local estimates untouched.
        return []
    }

    private static func login(email: String, password: String, baseURL: URL) async throws -> [String: Any] {
        var request = URLRequest(url: apiURL(for: baseURL, path: ["auth", "login"]))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Codex Dashboard", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password
        ])
        return try await responseObject(for: request)
    }

    private static func fetchAccounts(baseURL: URL, adminToken: String) async throws -> [Sub2APIAdminAccount] {
        var request = URLRequest(url: apiURL(for: baseURL, path: ["admin", "accounts"]))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(adminToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Codex Dashboard", forHTTPHeaderField: "User-Agent")
        let object = try await responseObject(for: request)
        let page = object["items"] as? [[String: Any]] ?? (object["data"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return page.compactMap { value in
            guard let rawID = number(value["id"]), rawID > 0 else { return nil }
            let id = Int64(rawID)
            let platform = (value["platform"] as? String) ?? ""
            let normalizedPlatform = platform.lowercased()
            guard normalizedPlatform.contains("openai") || normalizedPlatform.contains("codex") else { return nil }
            let name = (value["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "OpenAI account"
            return Sub2APIAdminAccount(id: id, name: name, platform: platform)
        }
    }

    private static func responseObject(for request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        if let code = root["code"] as? NSNumber, code.intValue != 0 {
            throw URLError(.badServerResponse)
        }
        return root["data"] as? [String: Any] ?? root
    }

    private static func apiURL(for baseURL: URL, path: [String]) -> URL {
        let normalizedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var url: URL
        if normalizedPath == "api/v1" || normalizedPath.hasSuffix("/api/v1") {
            url = baseURL
        } else if normalizedPath == "api" || normalizedPath.hasSuffix("/api") {
            url = baseURL.appendingPathComponent("v1")
        } else {
            url = baseURL.appendingPathComponent("api").appendingPathComponent("v1")
        }
        for component in path {
            url = url.appendingPathComponent(component)
        }
        return url
    }

    private static func quotaURL(for baseURL: URL, accountID: Int64) -> URL {
        apiURL(for: baseURL, path: ["admin", "openai", "accounts", String(accountID), "quota"])
    }

    private static func usageURL(for baseURL: URL, accountID: Int64) -> URL {
        apiURL(for: baseURL, path: ["admin", "accounts", String(accountID), "usage"])
    }

    private static func rateLimitWindows(from values: [[String: Any]]?) -> [UsageQuotaWindow] {
        (values ?? []).compactMap { value in
            guard let limit = number(value["limit"]), limit > 0,
                  let used = number(value["used"]),
                  let reset = date(value["reset_at"]) else { return nil }
            guard let minutes = windowMinutes(value["window"] as? String) else { return nil }
            return UsageQuotaWindow(
                usedPercent: min(100, max(0, used / limit * 100)),
                windowMinutes: minutes,
                resetsAt: reset
            )
        }
    }

    private static func subscriptionWindows(from value: [String: Any], observedAt: Date) -> [UsageQuotaWindow] {
        let definitions: [(usage: String, limit: String, minutes: Int)] = [
            ("daily_usage_usd", "daily_limit_usd", 1_440),
            ("weekly_usage_usd", "weekly_limit_usd", 10_080),
            ("monthly_usage_usd", "monthly_limit_usd", 43_200)
        ]
        return definitions.compactMap { definition in
            guard let used = number(value[definition.usage]),
                  let limit = number(value[definition.limit]), limit > 0,
                  let reset = subscriptionReset(for: definition.minutes, value: value, observedAt: observedAt) else {
                return nil
            }
            return UsageQuotaWindow(
                usedPercent: min(100, max(0, used / limit * 100)),
                windowMinutes: definition.minutes,
                resetsAt: reset
            )
        }
    }

    private static func subscriptionReset(for minutes: Int, value: [String: Any], observedAt: Date) -> Date? {
        if minutes == 10_080, let start = date(value["weekly_window_start"]) {
            return start.addingTimeInterval(7 * 86_400)
        }
        var calendar = Calendar.current
        calendar.timeZone = .current
        switch minutes {
        case 1_440:
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: observedAt))
        case 43_200:
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: observedAt))!
            return calendar.date(byAdding: .month, value: 1, to: start)
        default:
            return nil
        }
    }

    private static func windowMinutes(_ value: String?) -> Int? {
        switch value?.lowercased() {
        case "5h": return 300
        case "1d": return 1_440
        case "7d": return 10_080
        default: return nil
        }
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = number(value) { return Date(timeIntervalSince1970: number) }
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        number(value).map(Int.init)
    }

    private static func decimalString(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...8)))
    }
}

public struct BankedResetCredit: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let status: String
    public let grantedAt: Date
    public let expiresAt: Date?
    public let title: String?
    public let description: String?

    public init(
        id: String,
        status: String,
        grantedAt: Date,
        expiresAt: Date?,
        title: String?,
        description: String?
    ) {
        self.id = id
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.title = title
        self.description = description
    }
}

public struct BankedResetSnapshot: Codable, Hashable, Sendable {
    public let availableCount: Int
    public let credits: [BankedResetCredit]?
    public let observedAt: Date

    public init(availableCount: Int, credits: [BankedResetCredit]?, observedAt: Date = .now) {
        self.availableCount = max(0, availableCount)
        self.credits = credits
        self.observedAt = observedAt
    }
}

public enum BankedResetReader {
    private static let bankedResetURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// Fetches the OpenAI reset bank as read-only account metadata. This uses
    /// the same account credentials Codex already stores locally, but never
    /// writes or logs the token and never attempts to redeem a reset.
    public static func latest(from codexHome: URL) async -> BankedResetSnapshot? {
        guard let credentials = credentials(from: codexHome) else { return nil }

        do {
            return try await fetch(from: bankedResetURL, credentials: credentials)
        } catch {
            // Codex also falls back to the usage response when the dedicated
            // reset-credit endpoint is unavailable or rate-limited.
            return try? await fetch(from: usageURL, credentials: credentials)
        }
    }

    static func snapshot(from object: [String: Any], observedAt: Date = .now) -> BankedResetSnapshot? {
        let summary = object["rate_limit_reset_credits"] as? [String: Any]
            ?? object["rateLimitResetCredits"] as? [String: Any]
            ?? object
        let availableCount = integer(summary["available_count"] ?? summary["availableCount"])
        let rawCredits = summary["credits"] as? [[String: Any]]
        let credits = rawCredits?.compactMap { credit(from: $0) }
        guard let availableCount, availableCount >= 0 else { return nil }
        return BankedResetSnapshot(
            availableCount: availableCount,
            credits: rawCredits == nil ? nil : credits,
            observedAt: observedAt
        )
    }

    private static func fetch(
        from url: URL,
        credentials: (accessToken: String, accountID: String?)
    ) async throws -> BankedResetSnapshot {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Dashboard", forHTTPHeaderField: "originator")
        if let accountID = credentials.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshot = snapshot(from: object) else {
            throw URLError(.cannotParseResponse)
        }
        return snapshot
    }

    private static func credentials(from codexHome: URL) -> (accessToken: String, accountID: String?)? {
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else { return nil }
        return (accessToken, tokens["account_id"] as? String)
    }

    private static func credit(from object: [String: Any]) -> BankedResetCredit? {
        guard let id = object["id"] as? String,
              let status = object["status"] as? String,
              let grantedAt = date(object["granted_at"] ?? object["grantedAt"]) else { return nil }
        return BankedResetCredit(
            id: id,
            status: status,
            grantedAt: grantedAt,
            expiresAt: date(object["expires_at"] ?? object["expiresAt"]),
            title: object["title"] as? String,
            description: object["description"] as? String
        )
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

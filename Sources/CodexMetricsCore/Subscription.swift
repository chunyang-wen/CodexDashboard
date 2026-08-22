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
        if planType.caseInsensitiveCompare("api") == .orderedSame { return "API" }
        return planType.replacingOccurrences(of: "_", with: " ").capitalized
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
        .filter { $0.windowMinutes != 300 }
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
    /// Fetches the OpenAI reset bank as read-only account metadata. This uses
    /// the same account credentials Codex already stores locally, but never
    /// writes or logs the token and never attempts to redeem a reset.
    public static func latest(from codexHome: URL) async -> BankedResetSnapshot? {
        guard let credentials = credentials(from: codexHome),
              let url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits") else {
            return nil
        }

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
            return snapshot(from: object)
        } catch {
            // The menu bar should remain useful when the account endpoint is
            // unavailable, rate-limited, or the user is using an API provider.
            return nil
        }
    }

    static func snapshot(from object: [String: Any], observedAt: Date = .now) -> BankedResetSnapshot? {
        let availableCount = integer(object["available_count"] ?? object["availableCount"])
        let rawCredits = object["credits"] as? [[String: Any]]
        let credits = rawCredits?.compactMap { credit(from: $0) }
        guard let availableCount, availableCount >= 0 else { return nil }
        return BankedResetSnapshot(
            availableCount: availableCount,
            credits: rawCredits == nil ? nil : credits,
            observedAt: observedAt
        )
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

import Foundation

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
        planType.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

public enum SubscriptionReader {
    /// Reads only the tail of recent rollouts. Quota snapshots are emitted by Codex with
    /// token-count events, so this does not require credentials or a full history scan.
    public static func latest(from sessions: [SessionMetric]) -> SubscriptionSnapshot? {
        for session in sessions.prefix(20) where !session.rolloutPath.isEmpty {
            if let snapshot = latest(in: session.rolloutPath) { return snapshot }
        }
        return nil
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
            return snapshot(from: limits, timestamp: object["timestamp"] as? String)
        }
        return nil
    }

    private static func snapshot(from value: [String: Any], timestamp: String?) -> SubscriptionSnapshot {
        let windows = ["primary", "secondary", "individual_limit"].compactMap { key -> UsageQuotaWindow? in
            guard let window = value[key] as? [String: Any],
                  let used = number(window["used_percent"]),
                  let minutes = integer(window["window_minutes"]),
                  let reset = number(window["resets_at"]) else { return nil }
            return UsageQuotaWindow(usedPercent: used, windowMinutes: minutes, resetsAt: Date(timeIntervalSince1970: reset))
        }.sorted { $0.windowMinutes < $1.windowMinutes }

        let credits = (value["credits"] as? [String: Any]).map {
            SubscriptionCredits(
                hasCredits: ($0["has_credits"] as? Bool) ?? false,
                unlimited: ($0["unlimited"] as? Bool) ?? false,
                balance: $0["balance"] as? String
            )
        }
        return SubscriptionSnapshot(
            planType: value["plan_type"] as? String ?? "unknown",
            limitID: value["limit_id"] as? String ?? "codex",
            limitName: value["limit_name"] as? String,
            windows: windows,
            credits: credits,
            rateLimitReachedType: value["rate_limit_reached_type"] as? String,
            observedAt: parseDate(timestamp) ?? .now
        )
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

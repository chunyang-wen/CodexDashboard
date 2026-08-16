import Foundation

public struct ModelPrice: Codable, Hashable, Sendable {
    public let inputPerMillion: Decimal
    public let cachedInputPerMillion: Decimal
    public let cacheWriteMultiplier: Decimal
    public let outputPerMillion: Decimal

    public init(input: Decimal, cachedInput: Decimal, cacheWriteMultiplier: Decimal = 1, output: Decimal) {
        self.inputPerMillion = input
        self.cachedInputPerMillion = cachedInput
        self.cacheWriteMultiplier = cacheWriteMultiplier
        self.outputPerMillion = output
    }
}

public struct PricingRegistry: Sendable {
    public let prices: [String: ModelPrice]
    public let effectiveDate: String

    public init(prices: [String: ModelPrice], effectiveDate: String) {
        self.prices = prices
        self.effectiveDate = effectiveDate
    }

    /// API-equivalent list prices. Local ChatGPT/Codex subscription sessions are not token-billed invoices.
    public static let current = PricingRegistry(prices: [
        "gpt-5.6": .init(input: 5, cachedInput: 0.5, cacheWriteMultiplier: 1.25, output: 30),
        "gpt-5.6-sol": .init(input: 5, cachedInput: 0.5, cacheWriteMultiplier: 1.25, output: 30),
        "gpt-5.6-terra": .init(input: 2, cachedInput: 0.2, cacheWriteMultiplier: 1.25, output: 12),
        "gpt-5.6-luna": .init(input: 0.2, cachedInput: 0.02, cacheWriteMultiplier: 1.25, output: 1.2),
        "gpt-5.5": .init(input: 5, cachedInput: 0.5, output: 30),
        "gpt-5.4": .init(input: 2.5, cachedInput: 0.25, output: 15),
        "gpt-5.4-mini": .init(input: 0.75, cachedInput: 0.075, output: 4.5),
        "gpt-5.4-nano": .init(input: 0.2, cachedInput: 0.02, output: 1.25),
        "gpt-5.3-codex": .init(input: 1.75, cachedInput: 0.175, output: 14),
        "gpt-5.2": .init(input: 1.75, cachedInput: 0.175, output: 14),
        "gpt-5.2-codex": .init(input: 1.75, cachedInput: 0.175, output: 14),
        "gpt-5.1": .init(input: 1.25, cachedInput: 0.125, output: 10),
        "gpt-5.1-codex": .init(input: 1.25, cachedInput: 0.125, output: 10),
        "gpt-5.1-codex-max": .init(input: 1.25, cachedInput: 0.125, output: 10),
        "gpt-5.1-codex-mini": .init(input: 0.25, cachedInput: 0.025, output: 2),
        "gpt-5-codex": .init(input: 1.25, cachedInput: 0.125, output: 10)
    ], effectiveDate: "2026-07-30")

    public func price(for model: String?) -> ModelPrice? {
        guard let model else { return nil }
        if let exact = prices[model] { return exact }
        return prices.first { model.hasPrefix($0.key + "-") }?.value
    }

    public func estimate(usage: TokenUsage, model: String?) -> Decimal? {
        guard let price = price(for: model), usage.input > 0 || usage.output > 0 else { return nil }
        let million = Decimal(1_000_000)
        return Decimal(usage.uncachedInput) / million * price.inputPerMillion
            + Decimal(usage.cachedInput) / million * price.cachedInputPerMillion
            + Decimal(usage.cacheWriteInput) / million * price.inputPerMillion * price.cacheWriteMultiplier
            + Decimal(usage.output) / million * price.outputPerMillion
    }
}

public struct PricingSchedule: Codable, Hashable, Sendable {
    public let effectiveAt: Date
    public let prices: [String: ModelPrice]
    /// Where this rate card came from. Optional so archives created before source
    /// tracking was added continue to decode.
    public let source: String?

    public init(effectiveAt: Date, prices: [String: ModelPrice], source: String? = nil) {
        self.effectiveAt = effectiveAt
        self.prices = prices
        self.source = source
    }
}

public struct PricingHistory: Codable, Hashable, Sendable {
    public let schedules: [PricingSchedule]

    public init(schedules: [PricingSchedule]) {
        var byDate: [Date: PricingSchedule] = [:]
        for schedule in schedules { byDate[schedule.effectiveAt] = schedule }
        self.schedules = byDate.values.sorted { $0.effectiveAt < $1.effectiveAt }
    }

    public static let bundled: PricingHistory = {
        var launchPrices = PricingRegistry.current.prices
        launchPrices["gpt-5.6-terra"] = .init(input: 2.5, cachedInput: 0.25, cacheWriteMultiplier: 1.25, output: 15)
        launchPrices["gpt-5.6-luna"] = .init(input: 1, cachedInput: 0.1, cacheWriteMultiplier: 1.25, output: 6)
        return PricingHistory(schedules: [
            .init(effectiveAt: utcDate(2026, 7, 9), prices: launchPrices, source: "Bundled"),
            .init(effectiveAt: utcDate(2026, 7, 30), prices: PricingRegistry.current.prices, source: "Bundled")
        ])
    }()

    public func merging(_ other: PricingHistory) -> PricingHistory {
        PricingHistory(schedules: schedules + other.schedules)
    }

    public func price(for model: String?, on date: Date) -> ModelPrice? {
        let schedule = schedules.last(where: { $0.effectiveAt <= date }) ?? schedules.first
        guard let schedule else { return nil }
        return PricingRegistry(prices: schedule.prices, effectiveDate: "").price(for: model)
    }

    public func estimate(usage: TokenUsage, model: String?, on date: Date) -> Decimal? {
        guard let price = price(for: model, on: date), usage.input > 0 || usage.output > 0 else { return nil }
        let million = Decimal(1_000_000)
        return Decimal(usage.uncachedInput) / million * price.inputPerMillion
            + Decimal(usage.cachedInput) / million * price.cachedInputPerMillion
            + Decimal(usage.cacheWriteInput) / million * price.inputPerMillion * price.cacheWriteMultiplier
            + Decimal(usage.output) / million * price.outputPerMillion
    }

    public var latestEffectiveDate: Date? { schedules.last?.effectiveAt }
}

private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

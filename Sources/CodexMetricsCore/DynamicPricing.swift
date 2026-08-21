import Foundation

public struct DynamicPricingSnapshot: Sendable {
    public let prices: [String: ModelPrice]
    public let fetchedAt: Date
    public let fromCache: Bool

    public init(prices: [String: ModelPrice], fetchedAt: Date, fromCache: Bool) {
        self.prices = prices
        self.fetchedAt = fetchedAt
        self.fromCache = fromCache
    }
}

public enum DynamicPricingError: LocalizedError {
    case invalidResponse
    case responseTooLarge
    case noUsablePrices

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "The remote pricing catalog returned an invalid response."
        case .responseTooLarge: "The remote pricing catalog exceeded the 20 MB safety limit."
        case .noUsablePrices: "The remote pricing catalog contained no usable OpenAI token prices."
        }
    }
}

/// Refreshes a third-party models.dev catalog at most once per day. Bundled and
/// previously persisted schedules remain authoritative whenever refresh fails.
public actor DynamicPricingLoader {
    private struct State: Codable {
        var lastSuccess: Date?
        var etag: String?
        var lastModified: String?
    }

    private struct CachedCatalog: Codable {
        let prices: [String: ModelPrice]
    }

    private let catalogURL = URL(string: "https://models.dev/api.json")!
    private let cacheURL: URL
    private let stateURL: URL
    private let session: URLSession
    private let refreshInterval: TimeInterval
    private var memorySnapshot: DynamicPricingSnapshot?

    public init(
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        session: URLSession = .shared,
        refreshInterval: TimeInterval = 86_400
    ) {
        let directory = userHome.appendingPathComponent("Library/Caches/CodexDashboard", isDirectory: true)
        self.cacheURL = directory.appendingPathComponent("models-dev-pricing.json")
        self.stateURL = directory.appendingPathComponent("models-dev-pricing-state.json")
        self.session = session
        self.refreshInterval = refreshInterval
    }

    public func refresh(force: Bool = false, now: Date = .now) async throws -> DynamicPricingSnapshot {
        if !force,
           let memorySnapshot,
           now.timeIntervalSince(memorySnapshot.fetchedAt) < refreshInterval
        {
            return memorySnapshot
        }
        var state = loadState()
        if !force,
           let lastSuccess = state.lastSuccess,
           now.timeIntervalSince(lastSuccess) < refreshInterval,
           let cached = loadCached(fetchedAt: lastSuccess)
        {
            memorySnapshot = cached
            return cached
        }

        var request = URLRequest(url: catalogURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexDashboard/0.1", forHTTPHeaderField: "User-Agent")
        if let etag = state.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified = state.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw DynamicPricingError.invalidResponse }
            if http.statusCode == 304, let cached = loadCached(fetchedAt: now) {
                state.lastSuccess = now
                try persistState(state)
                memorySnapshot = cached
                return cached
            }
            guard http.statusCode == 200 else { throw DynamicPricingError.invalidResponse }
            guard data.count <= 20_000_000 else { throw DynamicPricingError.responseTooLarge }
            let snapshot = try Self.parse(data, fetchedAt: now, fromCache: false)
            try persistCache(snapshot.prices)
            state.lastSuccess = now
            state.etag = http.value(forHTTPHeaderField: "ETag")
            state.lastModified = http.value(forHTTPHeaderField: "Last-Modified")
            try persistState(state)
            memorySnapshot = snapshot
            return snapshot
        } catch {
            if let memorySnapshot {
                return DynamicPricingSnapshot(
                    prices: memorySnapshot.prices,
                    fetchedAt: memorySnapshot.fetchedAt,
                    fromCache: true
                )
            }
            if let lastSuccess = state.lastSuccess,
               let cached = loadCached(fetchedAt: lastSuccess) {
                memorySnapshot = cached
                return cached
            }
            throw error
        }
    }

    public static func parse(
        _ data: Data,
        fetchedAt: Date = .now,
        fromCache: Bool = false
    ) throws -> DynamicPricingSnapshot {
        guard data.count <= 20_000_000 else { throw DynamicPricingError.responseTooLarge }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let openAI = root["openai"] as? [String: Any],
              let models = openAI["models"] as? [String: Any] else {
            throw DynamicPricingError.invalidResponse
        }
        var prices: [String: ModelPrice] = [:]
        for (key, rawModel) in models {
            guard let model = rawModel as? [String: Any],
                  let identifier = (model["id"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? (key.isEmpty ? nil : key),
                  let cost = model["cost"] as? [String: Any],
                  let input = finiteNonnegative(cost["input"]),
                  let output = finiteNonnegative(cost["output"]),
                  input <= 1_000,
                  output <= 10_000 else { continue }
            let cached = finiteNonnegative(cost["cache_read"]) ?? input
            guard cached <= 1_000 else { continue }
            let cacheWrite = finiteNonnegative(cost["cache_write"])
            let multiplier = input > 0 ? Decimal(cacheWrite ?? input) / Decimal(input) : 1
            prices[identifier] = ModelPrice(
                input: Decimal(input),
                cachedInput: Decimal(cached),
                cacheWriteMultiplier: multiplier,
                output: Decimal(output)
            )
        }
        guard !prices.isEmpty else { throw DynamicPricingError.noUsablePrices }
        return DynamicPricingSnapshot(prices: prices, fetchedAt: fetchedAt, fromCache: fromCache)
    }

    private static func finiteNonnegative(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? NSNumber { number = value.doubleValue }
        else if let value = value as? String { number = Double(value) }
        else { number = nil }
        guard let number, number.isFinite, number >= 0 else { return nil }
        return number
    }

    private func loadState() -> State {
        guard let data = try? Data(contentsOf: stateURL),
              let value = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return value
    }

    /// Reads both the compact cache and the legacy full models.dev response. A
    /// successful legacy read is migrated atomically so it is paid only once.
    private func loadCached(fetchedAt: Date) -> DynamicPricingSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        if let cached = try? JSONDecoder().decode(CachedCatalog.self, from: data),
           !cached.prices.isEmpty {
            return DynamicPricingSnapshot(prices: cached.prices, fetchedAt: fetchedAt, fromCache: true)
        }
        guard let snapshot = try? Self.parse(data, fetchedAt: fetchedAt, fromCache: true) else {
            return nil
        }
        try? persistCache(snapshot.prices)
        return snapshot
    }

    private func persistCache(_ prices: [String: ModelPrice]) throws {
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(CachedCatalog(prices: prices))
            .write(to: cacheURL, options: .atomic)
    }

    private func persistState(_ state: State) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }
}

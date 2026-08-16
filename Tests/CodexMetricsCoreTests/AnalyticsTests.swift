import XCTest
@testable import CodexMetricsCore

final class AnalyticsTests: XCTestCase {
    func testTokenUsageDoesNotDoubleCountReasoning() {
        let usage = TokenUsage(input: 100, cachedInput: 60, output: 20, reasoningOutput: 8)
        XCTAssertEqual(usage.total, 120)
        XCTAssertEqual(usage.uncachedInput, 40)
        XCTAssertEqual(usage.cacheHitRate, 0.6, accuracy: 0.001)
    }

    func testCurrentSolPrice() {
        let usage = TokenUsage(input: 1_000_000, cachedInput: 800_000, output: 100_000)
        let cost = PricingRegistry.current.estimate(usage: usage, model: "gpt-5.6-sol")
        XCTAssertEqual(cost, Decimal(string: "4.4"))
    }

    func testCurrentLunaPrice() {
        let usage = TokenUsage(input: 1_000_000, cachedInput: 800_000, output: 100_000)
        let cost = PricingRegistry.current.estimate(usage: usage, model: "gpt-5.6-luna")
        XCTAssertEqual(cost, Decimal(string: "0.176"))
    }

    func testPercentiles() {
        XCTAssertEqual(Analytics.percentile([1, 2, 3, 4, 100], 0.5), 3)
        XCTAssertEqual(Analytics.percentile([1, 2, 3, 4, 100], 0.95), 100)
    }

    func testCompactTokenFormatting() {
        XCTAssertEqual(MetricFormatters.compactNumber(12_608_731), "12.6M")
        XCTAssertEqual(MetricFormatters.compactNumber(1_900_000_000), "1.9B")
        XCTAssertEqual(MetricFormatters.compactNumber(21_000), "21K")
    }

    func testRolloutParserExtractsUsageAndTiming() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        let lines = [
            #"{"timestamp":"2026-08-01T10:00:00.125Z","type":"turn_context","payload":{"model":"gpt-5.6-luna","effort":"high"}}"#,
            #"{"timestamp":"2026-08-01T10:00:01.250Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":100,"reasoning_output_tokens":20,"total_tokens":1100}}}}"#,
            #"{"timestamp":"2026-08-01T10:00:02.250Z","type":"event_msg","payload":{"type":"user_message","message":"hello"}}"#,
            #"{"timestamp":"2026-08-01T10:00:03.250Z","type":"response_item","payload":{"type":"function_call","name":"test"}}"#,
            #"{"timestamp":"2026-08-01T10:00:05.500Z","type":"event_msg","payload":{"type":"task_complete","duration_ms":4000,"time_to_first_token_ms":500,"completed_at":1785578405}}"#
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        let result = RolloutParser.parse(path: file.path)
        XCTAssertEqual(result.model, "gpt-5.6-luna")
        XCTAssertEqual(result.reasoningEffort, "high")
        XCTAssertEqual(result.usage.total, 1100)
        XCTAssertEqual(result.usage.cachedInput, 800)
        XCTAssertEqual(result.usageEvents.first?.model, "gpt-5.6-luna")
        XCTAssertEqual(result.usageEvents.first!.date.timeIntervalSince1970, 1_785_578_401.25, accuracy: 0.001)
        XCTAssertEqual(result.turns.first?.duration, 4)
        XCTAssertEqual(result.turns.first?.timeToFirstToken, 0.5)
        XCTAssertEqual(result.userMessages, 1)
        XCTAssertEqual(result.toolCalls, 1)
    }

    func testMixedModelSessionPricesEachDeltaWithItsActiveModel() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = [
            #"{"timestamp":"2026-08-01T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-luna"}}"#,
            #"{"timestamp":"2026-08-01T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":100,"total_tokens":1100}}}}"#,
            #"{"timestamp":"2026-08-02T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            #"{"timestamp":"2026-08-02T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000,"cached_input_tokens":1600,"output_tokens":200,"total_tokens":2200}}}}"#
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        let result = RolloutParser.parse(path: file.path)
        let session = SessionMetric(
            id: "mixed", rolloutPath: file.path, projectPath: "/tmp/project", title: "",
            source: "app", provider: "openai", createdAt: .distantPast, updatedAt: .now,
            model: "gpt-5.6-sol", reasoningEffort: nil, gitBranch: nil, cliVersion: nil,
            archived: false, usage: result.usage, usageEvents: result.usageEvents,
            enrichmentAvailable: true
        )

        XCTAssertEqual(result.usageEvents.map(\.model), ["gpt-5.6-luna", "gpt-5.6-sol"])
        XCTAssertEqual(Analytics.totalEstimatedCost([session]), Decimal(string: "0.004576"))
        XCTAssertEqual(Set(Analytics.models(from: [session]).map(\.model)), ["gpt-5.6-luna", "gpt-5.6-sol"])
    }

    func testHistoricalPricingUsesTheRateEffectiveOnEventDate() {
        let usage = TokenUsage(input: 1_000_000)
        let launch = PricingHistory.bundled.estimate(
            usage: usage,
            model: "gpt-5.6-luna",
            on: Date(timeIntervalSince1970: 1_784_505_600) // 2026-07-20 UTC
        )
        let reduced = PricingHistory.bundled.estimate(
            usage: usage,
            model: "gpt-5.6-luna",
            on: Date(timeIntervalSince1970: 1_785_542_400) // 2026-08-01 UTC
        )

        XCTAssertEqual(launch, Decimal(string: "1"))
        XCTAssertEqual(reduced, Decimal(string: "0.2"))
    }

    func testDynamicPricingCatalogParsesAndValidatesTokenRates() throws {
        let data = Data(#"{"openai":{"models":{"gpt-test":{"id":"gpt-test","cost":{"input":2,"output":12,"cache_read":0.2,"cache_write":2.5}},"bad":{"id":"bad","cost":{"input":-1,"output":12}}}}}"#.utf8)
        let snapshot = try DynamicPricingLoader.parse(data)
        let price = try XCTUnwrap(snapshot.prices["gpt-test"])

        XCTAssertEqual(price.inputPerMillion, Decimal(string: "2"))
        XCTAssertEqual(price.cachedInputPerMillion, Decimal(string: "0.2"))
        XCTAssertEqual(price.outputPerMillion, Decimal(string: "12"))
        XCTAssertEqual(price.cacheWriteMultiplier, Decimal(string: "1.25"))
        XCTAssertNil(snapshot.prices["bad"])
    }

    func testDynamicScheduleDoesNotRewriteEarlierCosts() {
        let futureDate = Date(timeIntervalSince1970: 1_800_000_000)
        var futurePrices = PricingRegistry.current.prices
        futurePrices["gpt-5.6-luna"] = .init(input: 0.3, cachedInput: 0.03, output: 1.8)
        let history = PricingHistory.bundled.merging(PricingHistory(schedules: [
            PricingSchedule(effectiveAt: futureDate, prices: futurePrices)
        ]))
        let usage = TokenUsage(input: 1_000_000)

        XCTAssertEqual(
            history.estimate(usage: usage, model: "gpt-5.6-luna", on: Date(timeIntervalSince1970: 1_785_542_400)),
            Decimal(string: "0.2")
        )
        XCTAssertEqual(
            history.estimate(usage: usage, model: "gpt-5.6-luna", on: futureDate),
            Decimal(string: "0.3")
        )
    }

    func testHistoricalStoreSurvivesExportAndImport() async throws {
        let firstHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let secondHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let exportURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: firstHome)
            try? FileManager.default.removeItem(at: secondHome)
            try? FileManager.default.removeItem(at: exportURL)
        }
        let event = UsageEvent(
            date: Date(timeIntervalSince1970: 1_785_542_400),
            usage: TokenUsage(input: 1_000, cachedInput: 800, output: 100),
            model: "gpt-5.6-luna"
        )
        let session = SessionMetric(
            id: "preserved", rolloutPath: "/missing/rollout.jsonl", projectPath: "/tmp/project",
            title: "Preserved", source: "app", provider: "openai",
            createdAt: event.date, updatedAt: event.date, model: "gpt-5.6-luna",
            reasoningEffort: nil, gitBranch: nil, cliVersion: nil, archived: false,
            usage: event.usage, usageEvents: [event], enrichmentAvailable: true
        )
        let first = HistoricalStore(userHome: firstHome)
        try await first.record([session])
        try await first.export(to: exportURL)

        let second = HistoricalStore(userHome: secondHome)
        let imported = try await second.importArchive(from: exportURL)
        _ = try await second.importArchive(from: exportURL)
        let restored = try await second.mergedSessions(with: [])
        let restoredPricing = try await second.pricingHistory()
        XCTAssertEqual(imported, 1)
        XCTAssertEqual(restored.map(\.id), ["preserved"])
        XCTAssertEqual(restored.first?.usageEvents, [event])
        XCTAssertEqual(restoredPricing.schedules.count, 2)
    }

    func testRangeUsesEventDatesInsteadOfWholeSessionTotal() {
        let cutoff = Date(timeIntervalSince1970: 1_000)
        let session = SessionMetric(
            id: "ranged", rolloutPath: "", projectPath: "/tmp/project", title: "",
            source: "app", provider: "openai", createdAt: .distantPast, updatedAt: .now,
            model: "gpt-5.6-sol", reasoningEffort: nil, gitBranch: nil, cliVersion: nil,
            archived: false, usage: TokenUsage(input: 3_000, output: 300),
            usageEvents: [
                UsageEvent(date: Date(timeIntervalSince1970: 900), usage: TokenUsage(input: 1_000, output: 100), model: "gpt-5.6-luna"),
                UsageEvent(date: Date(timeIntervalSince1970: 1_100), usage: TokenUsage(input: 2_000, output: 200), model: "gpt-5.6-sol")
            ],
            enrichmentAvailable: true
        )

        XCTAssertEqual(Analytics.totalUsage([session], since: cutoff).total, 2_200)
        XCTAssertEqual(Analytics.periods(from: [session], granularity: .day, since: cutoff).reduce(0) { $0 + $1.usage.total }, 2_200)
    }

    func testIndexedTotalIsNotInventedAsAUsageTrend() {
        let session = SessionMetric(
            id: "session",
            rolloutPath: "",
            projectPath: "/tmp/project",
            title: "Indexed only",
            source: "app",
            provider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            model: "gpt-5.6-sol",
            reasoningEffort: nil,
            gitBranch: nil,
            cliVersion: nil,
            archived: false,
            usage: TokenUsage(total: 1_000_000)
        )

        let periods = Analytics.periods(from: [session], granularity: .day)

        XCTAssertEqual(periods.reduce(0) { $0 + $1.usage.total }, 0)
    }

    func testRolloutParserHonorsCancellation() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"timestamp":"2026-08-01T10:00:00.125Z","type":"event_msg","payload":{"type":"user_message"}}"#.utf8).write(to: file)

        XCTAssertNil(RolloutParser.parse(path: file.path, shouldCancel: { true }))
    }

    func testRolloutParserResumesFromCachedByteOffset() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("growing.jsonl")
        let firstLine = #"{"timestamp":"2026-08-01T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110}}}}"# + "\n"
        try Data(firstLine.utf8).write(to: file)

        let first = try XCTUnwrap(RolloutParser.parseIncrementally(path: file.path, shouldCancel: { false }))
        XCTAssertEqual(first.enrichment.usage.total, 110)
        XCTAssertEqual(first.enrichment.usageEvents.map(\.usage.total), [110])

        let secondLine = #"{"timestamp":"2026-08-01T10:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250,"output_tokens":25,"total_tokens":275}}}}"# + "\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(secondLine.utf8))
        try handle.close()

        let resumed = try XCTUnwrap(RolloutParser.parseIncrementally(
            path: file.path,
            fromOffset: first.parsedBytes,
            initial: first.enrichment,
            shouldCancel: { false }
        ))
        XCTAssertEqual(resumed.enrichment.usage.total, 275)
        XCTAssertEqual(resumed.enrichment.usageEvents.map(\.usage.total), [110, 165])
        XCTAssertEqual(resumed.parsedBytes, UInt64(firstLine.utf8.count + secondLine.utf8.count))
    }

    func testRolloutParserDoesNotCheckpointPartialFinalLine() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let firstLine = #"{"timestamp":"2026-08-01T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110}}}}"# + "\n"
        let secondLine = #"{"timestamp":"2026-08-01T10:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250,"output_tokens":25,"total_tokens":275}}}}"#
        let split = secondLine.utf8.count / 2
        let partial = String(decoding: secondLine.utf8.prefix(split), as: UTF8.self)
        try Data((firstLine + partial).utf8).write(to: file)

        let first = try XCTUnwrap(RolloutParser.parseIncrementally(path: file.path, shouldCancel: { false }))
        XCTAssertEqual(first.parsedBytes, UInt64(firstLine.utf8.count))
        XCTAssertEqual(first.enrichment.usageEvents.map(\.usage.total), [110])

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(decoding: secondLine.utf8.dropFirst(split), as: UTF8.self) + "\n").utf8))
        try handle.close()

        let resumed = try XCTUnwrap(RolloutParser.parseIncrementally(
            path: file.path,
            fromOffset: first.parsedBytes,
            initial: first.enrichment,
            shouldCancel: { false }
        ))
        XCTAssertEqual(resumed.enrichment.usageEvents.map(\.usage.total), [110, 165])
        XCTAssertEqual(resumed.parsedBytes, UInt64(firstLine.utf8.count + secondLine.utf8.count + 1))
    }

    func testRolloutCacheTreatsFileGrowthAsIncrementalWork() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("growing.jsonl")
        try Data("first\n".utf8).write(to: file)
        let cache = RolloutCache(home: home)
        let enrichment = RolloutEnrichment(usage: TokenUsage(total: 10))
        cache.store(enrichment, for: file.path, parsedBytes: 6)
        let stored = try MetricsDatabase(userHome: home).rollout(for: file.path)
        XCTAssertNotNil(stored, "The transactional checkpoint should be readable immediately")
        XCTAssertEqual(stored?.fileSize, 6)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(stored?.deviceID, (attributes[.systemNumber] as? NSNumber)?.uint64Value)
        XCTAssertEqual(stored?.fileID, (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
        XCTAssertEqual(
            try XCTUnwrap(stored?.modifiedAt).timeIntervalSince1970,
            try XCTUnwrap(attributes[.modificationDate] as? Date).timeIntervalSince1970,
            accuracy: 0.001
        )

        guard case .complete = cache.lookup(file.path) else {
            return XCTFail("An unchanged rollout should be a complete cache hit")
        }
        guard case .complete = RolloutCache(home: home).lookup(file.path) else {
            return XCTFail("A new cache instance should load the SQLite checkpoint")
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("second\n".utf8))
        try handle.close()

        guard case .append(let cached, let offset) = cache.lookup(file.path) else {
            return XCTFail("An append-only rollout should resume from its cached offset")
        }
        XCTAssertEqual(cached.usage.total, 10)
        XCTAssertEqual(offset, 6)
    }

    func testRolloutCacheRejectsSameSizeFileReplacement() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("replaced.jsonl")
        try Data("first\n".utf8).write(to: file)
        let cache = RolloutCache(home: home)
        cache.store(RolloutEnrichment(usage: TokenUsage(total: 10)), for: file.path, parsedBytes: 6)

        try Data("other\n".utf8).write(to: file, options: .atomic)

        guard case .miss = cache.lookup(file.path) else {
            return XCTFail("A replaced rollout must not reuse metrics from the old file")
        }
    }

    func testRolloutParserSkipsLargeResponsePayloads() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let largePayload = String(repeating: "x", count: 2_000_000)
        let response = #"{"timestamp":"2026-08-01T10:00:00Z","type":"response_item","payload":{"type":"function_call_output","output":""# + largePayload + #""}}"#
        let usage = #"{"timestamp":"2026-08-01T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110}}}}"#
        try Data((response + "\n" + usage + "\n").utf8).write(to: file)

        let result = RolloutParser.parse(path: file.path)

        XCTAssertEqual(result.usage.total, 110)
        XCTAssertEqual(result.usageEvents.count, 1)
    }

    func testEnrichmentStreamPublishesEachCompletedSession() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        var sessions: [SessionMetric] = []
        for index in 0..<2 {
            let rollout = home.appendingPathComponent("rollout-\(index).jsonl")
            let total = (index + 1) * 100
            let line = #"{"timestamp":"2026-08-01T10:00:00.125Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":# + "\(total)" + #", "output_tokens":0,"total_tokens":# + "\(total)" + #"}}}}"#
            try Data((line + "\n").utf8).write(to: rollout)
            sessions.append(SessionMetric(
                id: "session-\(index)", rolloutPath: rollout.path, projectPath: home.path,
                title: "", source: "app", provider: "openai",
                createdAt: .distantPast, updatedAt: .now, model: "gpt-5.6-sol",
                reasoningEffort: nil, gitBranch: nil, cliVersion: nil, archived: false,
                usage: .init(total: Int64(total))
            ))
        }

        var progress: [EnrichmentProgress] = []
        for await update in CodexStore(codexHome: home, userHome: home).enrichmentStream(sessions) {
            progress.append(update)
        }

        XCTAssertEqual(progress.map(\.completed), [1, 2])
        XCTAssertEqual(progress.map(\.session.usage.total), [100, 200])
        XCTAssertTrue(progress.allSatisfy(\.session.enrichmentAvailable))
    }

    func testSubscriptionReaderExtractsDynamicQuotaWindows() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let line = #"{"timestamp":"2026-08-16T04:35:37.995Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":7,"window_minutes":300,"resets_at":1783308771},"secondary":{"used_percent":33,"window_minutes":10080,"resets_at":1783653502},"individual_limit":{"used_percent":15,"window_minutes":1440,"resets_at":1783400000},"credits":{"has_credits":true,"unlimited":false,"balance":"12.5"},"plan_type":"plus","rate_limit_reached_type":null}}}"#
        try Data((line + "\n").utf8).write(to: file)

        let snapshot = SubscriptionReader.latest(in: file.path)

        XCTAssertEqual(snapshot?.displayPlan, "Plus")
        XCTAssertEqual(snapshot?.windows.map(\.displayName), ["5-hour quota", "1-day quota", "Weekly quota"])
        XCTAssertEqual(snapshot?.windows.map(\.usedPercent), [7, 15, 33])
        XCTAssertEqual(snapshot?.credits?.balance, "12.5")
        XCTAssertEqual(try XCTUnwrap(snapshot).observedAt.timeIntervalSince1970, 1_786_854_937.995, accuracy: 0.001)
    }
}

import XCTest
import SQLite3
@testable import CodexMetricsCore

final class AnalyticsTests: XCTestCase {
    func testMenuBarSnapshotAndSessionCountLoadWithoutHydratedArchive() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = HistoricalStore(userHome: home)
        let session = SessionMetric(
            id: "compact", rolloutPath: "/tmp/compact.jsonl", projectPath: "/tmp/project",
            title: "Compact", source: "app", provider: "openai", createdAt: .now,
            updatedAt: .now, model: "gpt-5.6-luna", reasoningEffort: nil,
            gitBranch: nil, cliVersion: nil, archived: false,
            usage: TokenUsage(input: 10, output: 2), enrichmentAvailable: true
        )
        _ = try await store.record([session])
        let snapshotDate = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = MenuBarMetricsSnapshot(generatedAt: snapshotDate, days: [
            MenuBarDayMetrics(
                day: snapshotDate,
                usage: session.usage,
                estimatedCost: 1.25,
                toolCalls: 3,
                skillCalls: 1,
                sessions: 1,
                activeRuntime: 4
            )
        ])
        try await store.recordMenuBarMetrics(snapshot)
        await store.releaseMemory()

        let hydratedCount = try await store.sessionCount()
        await store.releaseMemory()
        let storedCount = try await store.storedSessionCount()
        let restoredSnapshot = try await store.menuBarMetricsSnapshot()
        XCTAssertEqual(hydratedCount, 1)
        XCTAssertEqual(storedCount, 1)
        XCTAssertEqual(restoredSnapshot, snapshot)
    }

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

    func testExactQuotaWindowTotalsExcludeResetBoundary() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(7 * 24 * 60 * 60)
        let includedUsage = TokenUsage(input: 1_000_000, cachedInput: 800_000, output: 100_000)
        let excludedUsage = TokenUsage(input: 50_000, output: 5_000)
        let session = SessionMetric(
            id: "quota-week",
            rolloutPath: "/tmp/quota-week.jsonl",
            projectPath: "/tmp",
            title: "Quota week",
            source: "test",
            provider: "openai",
            createdAt: start.addingTimeInterval(-1),
            updatedAt: end,
            model: "gpt-5.6-luna",
            reasoningEffort: nil,
            gitBranch: nil,
            cliVersion: nil,
            archived: false,
            usage: includedUsage + excludedUsage + excludedUsage,
            usageEvents: [
                UsageEvent(date: start.addingTimeInterval(-1), usage: excludedUsage, model: "gpt-5.6-luna"),
                UsageEvent(date: start, usage: includedUsage, model: "gpt-5.6-luna"),
                UsageEvent(date: end, usage: excludedUsage, model: "gpt-5.6-luna")
            ],
            enrichmentAvailable: true
        )
        let interval = DateInterval(start: start, end: end)

        XCTAssertEqual(Analytics.totalUsage([session], in: interval), includedUsage)
        XCTAssertEqual(
            Analytics.totalEstimatedCost([session], pricing: .bundled, in: interval),
            PricingHistory.bundled.estimate(usage: includedUsage, model: "gpt-5.6-luna", on: start)
        )
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
        XCTAssertEqual(result.toolCallEvents.map(\.name), ["test"])
    }

    func testConversationParserBuildsSentReceivedTimelineWithoutEventDuplicates() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = [
            #"{"timestamp":"2026-08-01T10:00:00Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"Be concise"}]}}"#,
            #"{"timestamp":"2026-08-01T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Hello"}]}}"#,
            #"{"timestamp":"2026-08-01T10:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"Hello"}}"#,
            #"{"timestamp":"2026-08-01T10:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hi"}]}}"#,
            #"{"timestamp":"2026-08-01T10:00:03Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"cmd\":\"pwd\"}","call_id":"call-1"}}"#,
            #"{"timestamp":"2026-08-01T10:00:04Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":"/tmp"}}"#,
            #"{"timestamp":"2026-08-01T10:00:05Z","type":"response_item","payload":{"type":"reasoning","encrypted_content":"opaque","summary":[]}}"#
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)

        let transcript = try ConversationParser.load(path: file.path)
        XCTAssertEqual(transcript.items.count, 6)
        XCTAssertEqual(transcript.items.map(\.direction), [.sent, .sent, .received, .received, .sent, .received])
        XCTAssertEqual(transcript.items.map(\.kind), [.instruction, .userMessage, .assistantMessage, .toolCall, .toolResult, .reasoning])
        XCTAssertEqual(transcript.items[1].body, "Hello")
        XCTAssertEqual(transcript.items[3].callID, "call-1")
        XCTAssertTrue(transcript.items[3].body.contains("\"cmd\" : \"pwd\""))
        XCTAssertEqual(transcript.items[5].title, "Reasoning context")
        XCTAssertEqual(
            transcript.items[5].body,
            "Codex retained encrypted reasoning state for conversation continuity. This rollout does not include a readable summary."
        )
        XCTAssertEqual(transcript.items[5].rawJSON, lines[6])
    }

    func testConversationTimelineUsesPlaintextReasoningWithoutChangingRawEvent() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let line = #"{"timestamp":"2026-08-01T10:00:00Z","type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"Short summary"}],"content":[{"type":"reasoning_text","text":"Readable reasoning details"}],"encrypted_content":"opaque"}}"#
        try Data((line + "\n").utf8).write(to: file)

        let item = try XCTUnwrap(ConversationParser.load(path: file.path).items.first)
        XCTAssertEqual(item.title, "Reasoning details")
        XCTAssertEqual(item.body, "Readable reasoning details")
        XCTAssertEqual(item.rawJSON, line)
    }

    func testConversationCopyRedactsCommonSecrets() {
        let item = ConversationItem(
            id: 0, date: nil, direction: .sent, kind: .toolCall, title: "Tool",
            body: #"{"api_key":"sk-exampleSecretValue123456","Authorization":"Bearer abc.def.secret"}"#,
            rawJSON: #"{"api_key":"sk-exampleSecretValue123456"}"#
        )
        XCTAssertFalse(item.redactedBody.contains("exampleSecretValue"))
        XCTAssertFalse(item.redactedBody.contains("abc.def.secret"))
        XCTAssertTrue(item.redactedBody.contains("REDACTED"))
        XCTAssertFalse(item.redactedRawJSON.contains("exampleSecretValue"))
    }

    func testToolCallsCaptureNamesAndShareFollowingTokenCost() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = [
            #"{"timestamp":"2026-08-01T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-luna"}}"#,
            #"{"timestamp":"2026-08-01T10:00:01Z","type":"response_item","payload":{"type":"function_call","name":"functions.exec","arguments":"{}"}}"#,
            #"{"timestamp":"2026-08-01T10:00:02Z","type":"response_item","payload":{"type":"custom_tool_call","name":"web.search","input":"query"}}"#,
            #"{"timestamp":"2026-08-01T10:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":100,"total_tokens":1100}}}}"#
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)

        let result = RolloutParser.parse(path: file.path)
        XCTAssertEqual(result.toolCallEvents.map(\.name), ["functions.exec", "web.search"])
        XCTAssertEqual(result.toolCallEvents.reduce(TokenUsage.zero) { $0 + $1.attributedUsage }, result.usage)

        let session = SessionMetric(
            id: "tools", rolloutPath: file.path, projectPath: "/tmp/project", title: "",
            source: "app", provider: "openai", createdAt: .distantPast, updatedAt: .now,
            model: result.model, reasoningEffort: nil, gitBranch: nil, cliVersion: nil,
            archived: false, usage: result.usage, usageEvents: result.usageEvents,
            toolCalls: result.toolCalls, toolCallEvents: result.toolCallEvents,
            enrichmentAvailable: true
        )
        let tools = Analytics.tools(from: [session])
        XCTAssertEqual(tools.map(\.tool), ["functions.exec", "web.search"])
        XCTAssertEqual(tools.reduce(TokenUsage.zero) { $0 + $1.attributedUsage }, result.usage)
        XCTAssertEqual(tools.reduce(Decimal.zero) { $0 + $1.estimatedCost }, Decimal(string: "0.000176"))
    }

    func testRolloutOriginatorAndNestedExecOperationAreDisplayed() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = [
            #"{"timestamp":"2026-08-01T10:00:00Z","type":"session_meta","payload":{"originator":"Codex Desktop","source":"vscode"}}"#,
            #"{"timestamp":"2026-08-01T10:00:01Z","type":"turn_context","payload":{"model":"gpt-5.6-luna"}}"#,
            #"{"timestamp":"2026-08-01T10:00:02Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.exec_command({cmd:\"sed -n '1,200p' /Users/test/.codex/skills/frontend-design/SKILL.md\"}); text(r.output)"}}"#,
            #"{"timestamp":"2026-08-01T10:00:03Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const a = await tools.web__run({}); const b = await tools.view_image({path:\"x\"});"}}"#,
            #"{"timestamp":"2026-08-01T10:00:03Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const patch = \"mentions tools.map(), tools.reduce(), and /fake/not-a-skill/SKILL.md\"; text(await tools.apply_patch(patch));"}}"#,
            #"{"timestamp":"2026-08-01T10:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":100,"total_tokens":1100}}}}"#
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)

        let result = RolloutParser.parse(path: file.path)
        XCTAssertEqual(result.originator, "Codex Desktop")
        XCTAssertEqual(result.toolCallEvents.map(\.name), [
            "exec → exec_command",
            "exec → web__run + view_image",
            "exec → apply_patch"
        ])
        XCTAssertEqual(result.skillCallEvents.map(\.name), ["frontend-design"])
        XCTAssertEqual(result.skillCallEvents.first?.attributedUsage.total, 1_100)

        let session = SessionMetric(
            id: "skills", rolloutPath: file.path, projectPath: "/tmp/project", title: "",
            source: "vscode", originator: result.originator, provider: "openai",
            createdAt: .distantPast, updatedAt: .now, model: result.model,
            reasoningEffort: nil, gitBranch: nil, cliVersion: nil, archived: false,
            usage: result.usage, usageEvents: result.usageEvents,
            toolCalls: result.toolCalls, toolCallEvents: result.toolCallEvents,
            skillCallEvents: result.skillCallEvents, enrichmentAvailable: true
        )
        let skills = Analytics.skills(from: [session])
        XCTAssertEqual(skills.map(\.skill), ["frontend-design"])
        XCTAssertEqual(skills.first?.calls, 1)
        XCTAssertEqual(skills.first?.estimatedCost, Decimal(string: "0.000176"))
    }

    func testHistoricalReenrichmentReplacesStaleToolLabels() async throws {
        let userHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: userHome) }
        let date = Date(timeIntervalSince1970: 1_785_542_400)
        func session(toolName: String) -> SessionMetric {
            SessionMetric(
                id: "reparsed", rolloutPath: "/tmp/rollout.jsonl", projectPath: "/tmp/project",
                title: "", source: "vscode", provider: "openai", createdAt: date,
                updatedAt: date, model: "gpt-5.6-luna", reasoningEffort: nil,
                gitBranch: nil, cliVersion: nil, archived: false, usage: .zero,
                toolCalls: 1,
                toolCallEvents: [.init(date: date, name: toolName, model: "gpt-5.6-luna")],
                enrichmentAvailable: true
            )
        }

        let store = HistoricalStore(userHome: userHome)
        try await store.record([session(toolName: "exec")])
        try await store.record([session(toolName: "exec → exec_command")])
        let restored = try await store.mergedSessions(with: [])
        XCTAssertEqual(restored.first?.toolCallEvents?.map(\.name), ["exec → exec_command"])
    }

    func testHistoricalMergeReusesEnrichmentUntilIndexAdvances() async throws {
        let userHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: userHome) }
        let date = Date(timeIntervalSince1970: 1_785_542_400)
        let event = UsageEvent(
            date: date,
            usage: TokenUsage(input: 1_000, output: 100),
            model: "gpt-5.6-luna"
        )
        let historical = SessionMetric(
            id: "cached", rolloutPath: "/tmp/rollout.jsonl", projectPath: "/tmp/project",
            title: "Cached", source: "app", provider: "openai", createdAt: date,
            updatedAt: date, model: "gpt-5.6-luna", reasoningEffort: nil,
            gitBranch: nil, cliVersion: nil, archived: false, usage: event.usage,
            usageEvents: [event], enrichmentAvailable: true
        )
        func indexed(updatedAt: Date) -> SessionMetric {
            SessionMetric(
                id: "cached", rolloutPath: "/tmp/rollout.jsonl", projectPath: "/tmp/project",
                title: "Cached", source: "app", provider: "openai", createdAt: date,
                updatedAt: updatedAt, model: "gpt-5.6-luna", reasoningEffort: nil,
                gitBranch: nil, cliVersion: nil, archived: false, usage: event.usage
            )
        }

        let store = HistoricalStore(userHome: userHome)
        try await store.record([historical])

        let unchanged = try await store.mergedSessions(with: [indexed(updatedAt: date)])
        let advanced = try await store.mergedSessions(with: [indexed(updatedAt: date.addingTimeInterval(1))])

        XCTAssertTrue(try XCTUnwrap(unchanged.first).enrichmentAvailable)
        XCTAssertFalse(try XCTUnwrap(advanced.first).enrichmentAvailable)
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
        let models = Analytics.models(from: [session])
        XCTAssertEqual(Set(models.map(\.model)), ["gpt-5.6-luna", "gpt-5.6-sol"])
        XCTAssertEqual(models.reduce(Decimal.zero) { $0 + $1.estimatedCost }, Analytics.totalEstimatedCost([session]))
        XCTAssertEqual(models.reduce(TokenUsage.zero) { $0 + $1.usage }, Analytics.totalUsage([session]))
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

    func testDynamicPricingMigratesLegacyCatalogAndReusesMemorySnapshot() async throws {
        struct PricingState: Codable {
            let lastSuccess: Date?
            let etag: String?
            let lastModified: String?
        }

        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cacheDirectory = home.appendingPathComponent("Library/Caches/CodexDashboard", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let fetchedAt = Date(timeIntervalSince1970: 1_786_800_000)
        let legacy = Data((#"{"openai":{"models":{"gpt-test":{"id":"gpt-test","cost":{"input":2,"output":12,"cache_read":0.2}}}},"padding":""#
            + String(repeating: "x", count: 20_000)
            + #""}"#).utf8)
        let cacheURL = cacheDirectory.appendingPathComponent("models-dev-pricing.json")
        let stateURL = cacheDirectory.appendingPathComponent("models-dev-pricing-state.json")
        try legacy.write(to: cacheURL)
        try JSONEncoder().encode(PricingState(lastSuccess: fetchedAt, etag: nil, lastModified: nil)).write(to: stateURL)

        let loader = DynamicPricingLoader(userHome: home)
        let first = try await loader.refresh(now: fetchedAt.addingTimeInterval(60))
        XCTAssertEqual(first.prices["gpt-test"]?.inputPerMillion, 2)
        XCTAssertTrue(first.fromCache)

        let compact = try Data(contentsOf: cacheURL)
        XCTAssertLessThan(compact.count, legacy.count / 10)
        let compactRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: compact) as? [String: Any])
        XCTAssertNotNil(compactRoot["prices"])
        XCTAssertNil(compactRoot["openai"])

        // Removing the file proves a repeated refresh is served from actor memory.
        try FileManager.default.removeItem(at: cacheURL)
        let second = try await loader.refresh(now: fetchedAt.addingTimeInterval(120))
        XCTAssertEqual(second.prices, first.prices)
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

    func testYearGranularityAggregatesEventsByCalendarYear() {
        let calendar = Calendar(identifier: .gregorian)
        let first = calendar.date(from: DateComponents(year: 2025, month: 12, day: 31))!
        let second = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let session = SessionMetric(
            id: "yearly", rolloutPath: "", projectPath: "/tmp/project", title: "",
            source: "app", provider: "openai", createdAt: first, updatedAt: second,
            model: "gpt-5.6-sol", reasoningEffort: nil, gitBranch: nil, cliVersion: nil,
            archived: false, usage: TokenUsage(input: 3_000),
            usageEvents: [
                UsageEvent(date: first, usage: TokenUsage(input: 1_000), model: "gpt-5.6-sol"),
                UsageEvent(date: second, usage: TokenUsage(input: 2_000), model: "gpt-5.6-sol")
            ],
            enrichmentAvailable: true
        )

        let periods = Analytics.periods(from: [session], granularity: .year, calendar: calendar)
        let combined = Analytics.periodBreakdowns(from: [session], calendar: calendar)[.year]

        XCTAssertEqual(periods.map { calendar.component(.year, from: $0.start) }, [2025, 2026])
        XCTAssertEqual(periods.map(\.usage.total), [1_000, 2_000])
        XCTAssertEqual(combined, periods)
    }

    func testDailyIndexRollsUpIntoWeekMonthAndYearWithoutRepricingEvents() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let firstDate = Date(timeIntervalSince1970: 1_785_542_400)
        let secondDate = firstDate.addingTimeInterval(2 * 86_400)
        let events = [
            UsageEvent(date: firstDate, usage: TokenUsage(input: 1_000, output: 100), model: "gpt-5.6-luna"),
            UsageEvent(date: secondDate, usage: TokenUsage(input: 2_000, output: 200), model: "gpt-5.6-luna")
        ]
        let session = SessionMetric(
            id: "indexed", rolloutPath: "/tmp/indexed.jsonl", projectPath: "/tmp/project-a",
            title: "", source: "app", provider: "openai", createdAt: firstDate,
            updatedAt: secondDate, model: "gpt-5.6-luna", reasoningEffort: nil,
            gitBranch: nil, cliVersion: nil, archived: false,
            usage: events.reduce(.zero) { $0 + $1.usage }, usageEvents: events,
            turns: [TurnMetric(completedAt: secondDate, duration: 4, timeToFirstToken: 0.5, completed: true)],
            enrichmentAvailable: true
        )
        let built = MetricsIndexBuilder.build(session: session, calendar: calendar)
        let index = MetricsIndexSnapshot(sessions: [built.session], days: built.days)

        XCTAssertEqual(index.periods(granularity: .day, calendar: calendar), Analytics.periods(from: [session], granularity: .day, calendar: calendar))
        XCTAssertEqual(index.periods(granularity: .week, calendar: calendar), Analytics.periods(from: [session], granularity: .week, calendar: calendar))
        XCTAssertEqual(index.periods(granularity: .month, calendar: calendar), Analytics.periods(from: [session], granularity: .month, calendar: calendar))
        XCTAssertEqual(index.periods(granularity: .year, calendar: calendar), Analytics.periods(from: [session], granularity: .year, calendar: calendar))
        XCTAssertEqual(index.aggregate().usage, Analytics.totalUsage([session]))
        XCTAssertEqual(index.aggregate().estimatedCost, Analytics.totalEstimatedCost([session]))
    }

    func testDurableMetricIndexUpdatesOnlyChangedSessionContribution() async throws {
        let userHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: userHome) }
        let date = Date(timeIntervalSince1970: 1_785_542_400)
        func session(id: String, project: String, tool: String) -> SessionMetric {
            let usage = TokenUsage(input: 1_000, output: 100)
            return SessionMetric(
                id: id, rolloutPath: "/tmp/\(id).jsonl", projectPath: project,
                title: "", source: "app", provider: "openai", createdAt: date,
                updatedAt: date, model: "gpt-5.6-luna", reasoningEffort: nil,
                gitBranch: nil, cliVersion: nil, archived: false, usage: usage,
                usageEvents: [UsageEvent(date: date, usage: usage, model: "gpt-5.6-luna")],
                toolCalls: 1,
                toolCallEvents: [ToolCallEvent(date: date, name: tool, model: "gpt-5.6-luna", attributedUsage: usage)],
                enrichmentAvailable: true
            )
        }

        let originalA = session(id: "a", project: "/tmp/a", tool: "old-label")
        let originalB = session(id: "b", project: "/tmp/b", tool: "unchanged")
        let store = HistoricalStore(userHome: userHome)
        let first = try await store.metricsIndex(for: [originalA, originalB])
        XCTAssertEqual(first.sessions.count, 2)
        XCTAssertEqual(first.aggregate(projectPath: "/tmp/a").tools.map(\.tool), ["old-label"])

        // Same timestamp and event count, but a parser-produced label changed.
        let renamedA = session(id: "a", project: "/tmp/a", tool: "new-label")
        let updated = try await store.metricsIndex(for: [renamedA, originalB])
        XCTAssertEqual(updated.aggregate(projectPath: "/tmp/a").tools.map(\.tool), ["new-label"])
        XCTAssertEqual(updated.aggregate(projectPath: "/tmp/b").tools.map(\.tool), ["unchanged"])

        // A new actor proves the index was stored in SQLite rather than retained only in memory.
        let reopened = HistoricalStore(userHome: userHome)
        let restored = try await reopened.metricsIndex(for: [renamedA, originalB])
        XCTAssertEqual(restored.sessions.count, 2)
        XCTAssertEqual(restored.days.count, 2)
        XCTAssertEqual(restored.aggregate(projectPath: "/tmp/a").usage, renamedA.usage)
        XCTAssertEqual(restored.aggregate(projectPath: "/tmp/b").usage, originalB.usage)
    }

    func testRecordingNewSessionInvalidatesCachedMetricIndex() async throws {
        let userHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: userHome) }
        let date = Date(timeIntervalSince1970: 1_785_542_400)
        func session(id: String, model: String) -> SessionMetric {
            let usage = TokenUsage(input: 100, output: 10, total: 110)
            return SessionMetric(
                id: id, rolloutPath: "/tmp/\(id).jsonl", projectPath: "/tmp/project",
                title: "", source: "app", provider: "openrouter", createdAt: date,
                updatedAt: date, model: model, reasoningEffort: nil, gitBranch: nil,
                cliVersion: nil, archived: false, usage: usage,
                usageEvents: [UsageEvent(date: date, usage: usage, model: model)],
                enrichmentAvailable: true
            )
        }

        let store = HistoricalStore(userHome: userHome)
        let first = session(id: "first", model: "gpt-5.6-luna")
        _ = try await store.record([first])
        _ = try await store.metricsIndex()
        let second = session(id: "second", model: "stealth/ox-alpha")
        _ = try await store.record([second])

        let refreshed = try await store.metricsIndex()
        XCTAssertEqual(refreshed.sessions.count, 2)
        XCTAssertTrue(refreshed.aggregate().models.contains { $0.model == "stealth/ox-alpha" })
    }

    func testMetricIndexAggregateUsesAnEndExclusivePeriodWithoutRescanningSessions() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let firstDay = Date(timeIntervalSince1970: 1_788_739_200)
        let secondDay = calendar.date(byAdding: .day, value: 1, to: firstDay)!
        let end = calendar.date(byAdding: .day, value: 2, to: firstDay)!
        let firstUsage = TokenUsage(input: 100, output: 10)
        let secondUsage = TokenUsage(input: 200, output: 20)
        let session = SessionMetric(
            id: "period", rolloutPath: "/tmp/period.jsonl", projectPath: "/tmp/project",
            title: "", source: "app", provider: "openai", createdAt: firstDay,
            updatedAt: secondDay, model: "gpt-5.6-luna", reasoningEffort: nil,
            gitBranch: nil, cliVersion: nil, archived: false,
            usage: firstUsage + secondUsage,
            usageEvents: [
                UsageEvent(date: firstDay, usage: firstUsage, model: "gpt-5.6-luna"),
                UsageEvent(date: secondDay, usage: secondUsage, model: "gpt-5.6-luna")
            ],
            turns: [
                TurnMetric(completedAt: firstDay, duration: 3, timeToFirstToken: 0.3, completed: true),
                TurnMetric(completedAt: secondDay, duration: 7, timeToFirstToken: 0.7, completed: true)
            ],
            toolCallEvents: [
                ToolCallEvent(date: firstDay, name: "first", model: "gpt-5.6-luna"),
                ToolCallEvent(date: secondDay, name: "second", model: "gpt-5.6-luna")
            ],
            skillCallEvents: [
                SkillCallEvent(date: firstDay, name: "one", model: "gpt-5.6-luna"),
                SkillCallEvent(date: secondDay, name: "two", model: "gpt-5.6-luna")
            ],
            enrichmentAvailable: true
        )
        let built = MetricsIndexBuilder.build(session: session, calendar: calendar)
        let index = MetricsIndexSnapshot(sessions: [built.session], days: built.days)

        let first = index.aggregate(in: DateInterval(start: firstDay, end: secondDay))
        XCTAssertEqual(first.usage, firstUsage)
        XCTAssertEqual(first.activeDays, 1)
        XCTAssertEqual(first.turnDurations, [3])
        XCTAssertEqual(first.firstTokenTimes, [0.3])
        XCTAssertEqual(first.toolCalls, 1)
        XCTAssertEqual(first.skillCalls, 1)
        XCTAssertEqual(first.tools.map(\.tool), ["first"])
        XCTAssertEqual(first.skills.map(\.skill), ["one"])

        let both = index.aggregate(in: DateInterval(start: firstDay, end: end))
        XCTAssertEqual(both.usage, firstUsage + secondUsage)
        XCTAssertEqual(both.activeDays, 2)
        XCTAssertEqual(both.toolCalls, 2)
        XCTAssertEqual(both.skillCalls, 2)
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
        XCTAssertEqual(snapshot?.windows.map(\.displayName), ["1-day quota", "Weekly quota"])
        XCTAssertEqual(snapshot?.windows.map(\.usedPercent), [15, 33])
        XCTAssertEqual(snapshot?.credits?.balance, "12.5")
        XCTAssertEqual(try XCTUnwrap(snapshot).observedAt.timeIntervalSince1970, 1_786_854_937.995, accuracy: 0.001)
    }

    func testSubscriptionReaderIgnoresProviderPlaceholderQuota() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let line = #"{"timestamp":"2026-08-22T02:02:59.827Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":null,"secondary":null,"credits":null,"individual_limit":null,"plan_type":null,"rate_limit_reached_type":null}}}"#
        try Data((line + "\n").utf8).write(to: file)

        XCTAssertNil(SubscriptionReader.latest(in: file.path))
    }

    func testSubscriptionReaderSkipsNewestPlaceholderForOlderQuota() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let valid = #"{"timestamp":"2026-08-22T02:00:00.000Z","payload":{"rate_limits":{"secondary":{"used_percent":40,"window_minutes":10080,"resets_at":1787803180},"plan_type":"plus"}}}"#
        let placeholder = #"{"timestamp":"2026-08-22T02:02:59.827Z","payload":{"rate_limits":{"primary":null,"secondary":null,"credits":null,"plan_type":null}}}"#
        try Data((valid + "\n" + placeholder + "\n").utf8).write(to: file)

        XCTAssertEqual(SubscriptionReader.latest(in: file.path)?.windows.first?.usedPercent, 40)
    }

    func testRolloutParserPersistsQuotaSnapshotWithEnrichment() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let line = #"{"timestamp":"2026-08-16T04:35:37.995Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110}},"rate_limits":{"limit_id":"codex","secondary":{"used_percent":33,"window_minutes":10080,"resets_at":1783653502},"plan_type":"plus"}}}"#
        try Data((line + "\n").utf8).write(to: file)

        let enrichment = RolloutParser.parse(path: file.path)

        XCTAssertEqual(enrichment.subscription?.displayPlan, "Plus")
        XCTAssertEqual(enrichment.subscription?.windows.first?.usedPercent, 33)
        XCTAssertEqual(try XCTUnwrap(enrichment.subscription).observedAt.timeIntervalSince1970, 1_786_854_937.995, accuracy: 0.001)
    }

    func testRolloutParserDoesNotPersistProviderPlaceholderQuota() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let line = #"{"timestamp":"2026-08-22T02:02:59.827Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110}},"rate_limits":{"limit_id":"codex","primary":null,"secondary":null,"credits":null,"individual_limit":null,"plan_type":null,"rate_limit_reached_type":null}}}"#
        try Data((line + "\n").utf8).write(to: file)

        XCTAssertNil(RolloutParser.parse(path: file.path).subscription)
    }

    func testCachedSubscriptionLookupDoesNotRequireRolloutFiles() {
        let older = SubscriptionSnapshot(
            planType: "plus", limitID: "codex", limitName: nil, windows: [], credits: nil,
            rateLimitReachedType: nil, observedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = SubscriptionSnapshot(
            planType: "pro", limitID: "codex", limitName: nil, windows: [], credits: nil,
            rateLimitReachedType: nil, observedAt: Date(timeIntervalSince1970: 200)
        )
        func session(id: String, subscription: SubscriptionSnapshot?) -> SessionMetric {
            SessionMetric(
                id: id, rolloutPath: "/path/that/does/not/exist", projectPath: "/tmp/project", title: "",
                source: "app", provider: "openai", createdAt: .distantPast, updatedAt: .now,
                model: nil, reasoningEffort: nil, gitBranch: nil, cliVersion: nil, archived: false,
                usage: .zero, subscription: subscription, enrichmentAvailable: true
            )
        }

        let snapshot = SubscriptionReader.latestCached(from: [
            session(id: "older", subscription: older),
            session(id: "none", subscription: nil),
            session(id: "newer", subscription: newer)
        ])

        XCTAssertEqual(snapshot?.planType, "pro")
        XCTAssertEqual(snapshot?.observedAt, newer.observedAt)
    }

    func testSessionMetricDecodesArchiveWrittenBeforeCachedSubscription() throws {
        let session = SessionMetric(
            id: "legacy", rolloutPath: "/tmp/legacy.jsonl", projectPath: "/tmp/project", title: "",
            source: "app", provider: "openai", createdAt: .distantPast, updatedAt: .now,
            model: nil, reasoningEffort: nil, gitBranch: nil, cliVersion: nil, archived: false,
            usage: .zero, enrichmentAvailable: true
        )
        let encoded = try JSONEncoder().encode(session)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "subscription")

        let decoded = try JSONDecoder().decode(
            SessionMetric.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.subscription)
        XCTAssertEqual(decoded.id, session.id)
    }

    func testHistoricalStoreDoesNotRewriteIdenticalSession() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = HistoricalStore(userHome: home)
        let session = SessionMetric(
            id: "stable", rolloutPath: "/tmp/stable.jsonl", projectPath: "/tmp/project", title: "Stable",
            source: "app", provider: "openai", createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200), model: "gpt-test", reasoningEffort: nil,
            gitBranch: nil, cliVersion: nil, archived: false, usage: TokenUsage(total: 10),
            enrichmentAvailable: true
        )

        let firstCount = try await store.record([session])
        XCTAssertEqual(firstCount, 1)
        let databaseURL = home.appendingPathComponent("Library/Application Support/CodexDashboard/metrics-v1.sqlite")
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let databaseBefore = try Data(contentsOf: databaseURL)
        let walBefore = try Data(contentsOf: walURL)

        let secondCount = try await store.record([session])
        XCTAssertEqual(secondCount, 1)

        XCTAssertEqual(try Data(contentsOf: databaseURL), databaseBefore)
        XCTAssertEqual(try Data(contentsOf: walURL), walBefore)
    }

    func testHistoricalStorePersistsNewestSubscriptionWithoutRegressing() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let older = SubscriptionSnapshot(
            planType: "plus", limitID: "codex", limitName: nil, windows: [], credits: nil,
            rateLimitReachedType: nil, observedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = SubscriptionSnapshot(
            planType: "pro", limitID: "codex", limitName: nil, windows: [], credits: nil,
            rateLimitReachedType: nil, observedAt: Date(timeIntervalSince1970: 200)
        )
        let writer = HistoricalStore(userHome: home)
        try await writer.recordSubscription(newer)
        try await writer.recordSubscription(older)

        let reader = HistoricalStore(userHome: home)
        let persisted = try await reader.subscriptionSnapshot()

        XCTAssertEqual(persisted, newer)
    }

    func testCodexSourcePathClassifierRecognizesOnlyRolloutsAndIndexFiles() {
        let home = URL(fileURLWithPath: "/tmp/custom-codex", isDirectory: true)
        let classifier = CodexSourcePathClassifier(codexHome: home)
        let rollout = "/tmp/custom-codex/sessions/2026/08/21/rollout-test.jsonl"

        XCTAssertEqual(classifier.classify(rollout), .rollout(rollout))
        XCTAssertEqual(classifier.classify("/tmp/custom-codex/state_5.sqlite"), .index)
        XCTAssertEqual(classifier.classify("/tmp/custom-codex/state_5.sqlite-wal"), .index)
        XCTAssertEqual(classifier.classify("/tmp/custom-codex/sqlite/state_5.sqlite-journal"), .index)
        XCTAssertEqual(classifier.classify("/tmp/custom-codex/generated_images/image.png"), .irrelevant)
        XCTAssertEqual(classifier.classify("/tmp/custom-codex/sessions/2026/08/21/note.txt"), .irrelevant)
        XCTAssertEqual(classifier.classify("/tmp/custom-codex-other/sessions/rollout.jsonl"), .irrelevant)
    }

    func testHistoricalStoreKeepsIndependentMonotonicEventCursorsPerCodexHome() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let firstCodexHome = home.appendingPathComponent("first", isDirectory: true)
        let secondCodexHome = home.appendingPathComponent("second", isDirectory: true)
        let writer = HistoricalStore(userHome: home)

        try await writer.recordSourceEventID(200, for: firstCodexHome)
        try await writer.recordSourceEventID(100, for: firstCodexHome)
        try await writer.recordSourceEventID(300, for: secondCodexHome)

        let reader = HistoricalStore(userHome: home)
        let first = try await reader.sourceEventID(for: firstCodexHome)
        let second = try await reader.sourceEventID(for: secondCodexHome)
        XCTAssertEqual(first, 200)
        XCTAssertEqual(second, 300)
    }

    func testSubscriptionReaderChoosesNewestSnapshotAcrossRecentSessions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let olderFile = directory.appendingPathComponent("older.jsonl")
        let newerFile = directory.appendingPathComponent("newer.jsonl")
        func line(timestamp: String, usedPercent: Int) -> String {
            #"{"timestamp":"\#(timestamp)","payload":{"rate_limits":{"limit_id":"codex","secondary":{"used_percent":\#(usedPercent),"window_minutes":10080,"resets_at":1783653502},"plan_type":"plus"}}}"#
        }
        try Data((line(timestamp: "2026-08-16T04:00:00.000Z", usedPercent: 10) + "\n").utf8).write(to: olderFile)
        try Data((line(timestamp: "2026-08-16T05:00:00.000Z", usedPercent: 20) + "\n").utf8).write(to: newerFile)
        func session(id: String, path: String) -> SessionMetric {
            SessionMetric(
                id: id, rolloutPath: path, projectPath: "/tmp/project", title: "",
                source: "app", provider: "openai", createdAt: .distantPast,
                updatedAt: .now, model: nil, reasoningEffort: nil, gitBranch: nil,
                cliVersion: nil, archived: false, usage: .zero
            )
        }

        // Session ordering is not a reliable proxy for the embedded quota timestamp.
        let snapshot = SubscriptionReader.latest(from: [
            session(id: "older", path: olderFile.path),
            session(id: "newer", path: newerFile.path)
        ])

        XCTAssertEqual(snapshot?.windows.first?.usedPercent, 20)
        XCTAssertEqual(snapshot?.observedAt.timeIntervalSince1970, 1_786_856_400)
    }

    func testCodexStoreFallsBackToSecondaryDatabaseLocation() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        let secondaryDirectory = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: secondaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // A present but invalid primary database must not prevent reading the valid
        // secondary location used by some Codex versions.
        try Data("not a sqlite database".utf8).write(to: codexHome.appendingPathComponent("state_5.sqlite"))
        let secondary = secondaryDirectory.appendingPathComponent("state_5.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(secondary.path, &database), SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "CREATE TABLE threads (id TEXT, updated_at INTEGER); INSERT INTO threads VALUES ('fallback-session', 123);",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )

        let sessions = try CodexStore(codexHome: codexHome, userHome: home).loadIndexedSessions()
        XCTAssertEqual(sessions.map(\.id), ["fallback-session"])
    }

    func testHistoricalStoreReleaseMemoryFlushesCaches() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let store = HistoricalStore(userHome: home)
        let sample = SessionMetric(
            id: "mem-test-1", rolloutPath: "/tmp/mem.jsonl", projectPath: "/tmp/project",
            title: "Memory Test", source: "cli", provider: "openai",
            createdAt: .distantPast, updatedAt: .now, model: "gpt-4o",
            reasoningEffort: nil, gitBranch: nil, cliVersion: nil,
            archived: false, usage: .init(input: 100, output: 50, total: 150),
            enrichmentAvailable: true
        )

        let count = try await store.record([sample])
        XCTAssertEqual(count, 1)

        let index = try await store.metricsIndex(for: [sample])
        XCTAssertEqual(index.sessions.count, 1)

        // Calling releaseMemory should reset in-memory caches and SQLite connection pages
        await store.releaseMemory()

        // Re-reading count or index should succeed on-demand without error
        let storedCount = try await store.storedSessionCount()
        XCTAssertEqual(storedCount, 1)

        let storedPricing = try await store.storedPricingHistory()
        XCTAssertFalse(storedPricing.schedules.isEmpty)
    }

    func testHistoricalStoreSessionOnDemandFetchAndSummaries() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let store = HistoricalStore(userHome: home)
        let sample = SessionMetric(
            id: "on-demand-1", rolloutPath: "/tmp/sample.jsonl", projectPath: "/tmp/project",
            title: "On Demand Test", source: "cli", provider: "openai",
            createdAt: .distantPast, updatedAt: .now, model: "gpt-4o",
            reasoningEffort: nil, gitBranch: nil, cliVersion: nil,
            archived: false, usage: .init(input: 100, output: 50, total: 150),
            turns: [TurnMetric(completedAt: .now, duration: 2.5, timeToFirstToken: 0.2, completed: true)],
            toolCalls: 3,
            enrichmentAvailable: true
        )

        _ = try await store.record([sample])
        await store.releaseMemory()

        // Test fetching summaries without loading full SessionMetric objects into memory
        let summaries = try await store.sessionSummaries()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.id, "on-demand-1")
        XCTAssertEqual(summaries.first?.displayTitle, "On Demand Test")
        XCTAssertEqual(summaries.first?.toolCalls, 3)

        // Test fetching single session on demand from SQLite
        let fetched = try await store.session(withID: "on-demand-1")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, "on-demand-1")
        XCTAssertEqual(fetched?.turns.count, 1)
        XCTAssertEqual(fetched?.turns.first?.duration, 2.5)

        // Non-existent session returns nil
        let nonExistent = try await store.session(withID: "non-existent")
        XCTAssertNil(nonExistent)
    }
}

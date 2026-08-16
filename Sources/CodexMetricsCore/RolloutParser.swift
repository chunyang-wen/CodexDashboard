import Foundation

struct RolloutEnrichment: Codable, Sendable {
    var usage: TokenUsage = .zero
    var usageEvents: [UsageEvent] = []
    var turns: [TurnMetric] = []
    var model: String?
    var reasoningEffort: String?
    var toolCalls = 0
    var userMessages = 0
    var abortedTurns = 0
}

struct CachedRollout: Codable, Sendable {
    let fileSize: Int64
    let modifiedAt: Date
    let enrichment: RolloutEnrichment
    let deviceID: UInt64?
    let fileID: UInt64?
    let boundaryHash: UInt64?

    init(
        fileSize: Int64,
        modifiedAt: Date,
        enrichment: RolloutEnrichment,
        deviceID: UInt64? = nil,
        fileID: UInt64? = nil,
        boundaryHash: UInt64? = nil
    ) {
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.enrichment = enrichment
        self.deviceID = deviceID
        self.fileID = fileID
        self.boundaryHash = boundaryHash
    }
}

final class RolloutCache {
    enum Lookup {
        case complete(RolloutEnrichment)
        case append(RolloutEnrichment, fromOffset: UInt64)
        case miss
    }

    private var entries: [String: CachedRollout]
    private let url: URL
    private let database: MetricsDatabase?

    init(home: URL) {
        let directory = home.appendingPathComponent("Library/Caches/CodexDashboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // v4 adds the active model to every token delta. Older cache entries only kept
        // the final session model and cannot price sessions that switched models.
        url = directory.appendingPathComponent("rollouts-v4.json")
        database = try? MetricsDatabase(userHome: home)
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String: CachedRollout].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
        if let database {
            for (path, cached) in entries where database.rollout(for: path) == nil {
                try? database.storeRollout(cached, for: path)
            }
        }
    }

    func lookup(_ path: String) -> Lookup {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return .miss }
        let cached = database?.rollout(for: path) ?? entries[path]
        guard let cached else { return .miss }
        let deviceID = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let identityChanged = (cached.deviceID != nil && deviceID != nil && cached.deviceID != deviceID)
            || (cached.fileID != nil && fileID != nil && cached.fileID != fileID)
        let boundaryChanged = cached.boundaryHash.map {
            Self.boundaryHash(path: path, through: cached.fileSize) != $0
        } == true
        if identityChanged || boundaryChanged {
            return .miss
        }
        if cached.fileSize == size.int64Value {
            if cached.boundaryHash != nil || cached.modifiedAt == modified {
                return .complete(cached.enrichment)
            }
            return .miss
        }
        // Codex rollouts are append-only. Preserve all previously extracted metrics
        // and scan only bytes written since the last successful checkpoint.
        if cached.fileSize > 0, cached.fileSize < size.int64Value {
            return .append(cached.enrichment, fromOffset: UInt64(cached.fileSize))
        }
        return .miss
    }

    func store(_ enrichment: RolloutEnrichment, for path: String, parsedBytes: UInt64) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else { return }
        entries[path] = CachedRollout(
            fileSize: Int64(clamping: parsedBytes),
            modifiedAt: modified,
            enrichment: enrichment,
            deviceID: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            fileID: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            boundaryHash: Self.boundaryHash(path: path, through: Int64(clamping: parsedBytes))
        )
        if let cached = entries[path] { try? database?.storeRollout(cached, for: path) }
    }

    func persist() {
        guard database == nil else {
            // Remove the legacy cache only after every in-memory entry has reached
            // SQLite. Failure is harmless: it remains available for migration.
            if entries.allSatisfy({ database?.rollout(for: $0.key) != nil }) {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Hashes bytes immediately before the committed boundary. This cheaply catches
    /// path reuse or an in-place rewrite even when inode, size, or timestamp is reused.
    private static func boundaryHash(path: String, through offset: Int64) -> UInt64? {
        guard offset >= 0, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let count = min(Int64(4_096), offset)
        do {
            try handle.seek(toOffset: UInt64(offset - count))
            guard let bytes = try handle.read(upToCount: Int(count)) else { return nil }
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            return hash
        } catch {
            return nil
        }
    }
}

enum RolloutParser {
    struct ParseResult: Sendable {
        let enrichment: RolloutEnrichment
        let parsedBytes: UInt64
    }

    private static let eventMessageMarker = Data(#""type":"event_msg""#.utf8)
    private static let turnContextMarker = Data(#""type":"turn_context""#.utf8)
    private static let responseItemMarker = Data(#""type":"response_item""#.utf8)
    private static let tokenCountMarker = Data(#""type":"token_count""#.utf8)
    private static let taskCompleteMarker = Data(#""type":"task_complete""#.utf8)
    private static let turnAbortedMarker = Data(#""type":"turn_aborted""#.utf8)
    private static let userMessageMarker = Data(#""type":"user_message""#.utf8)
    private static let functionCallMarker = Data(#""type":"function_call""#.utf8)
    private static let customToolCallMarker = Data(#""type":"custom_tool_call""#.utf8)

    static func parse(path: String) -> RolloutEnrichment {
        parse(path: path, shouldCancel: { false }) ?? .init()
    }

    static func parse(path: String, shouldCancel: () -> Bool) -> RolloutEnrichment? {
        parseIncrementally(path: path, shouldCancel: shouldCancel)?.enrichment
    }

    static func parseIncrementally(
        path: String,
        fromOffset: UInt64 = 0,
        initial: RolloutEnrichment = .init(),
        shouldCancel: () -> Bool
    ) -> ParseResult? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return ParseResult(enrichment: initial, parsedBytes: fromOffset)
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: fromOffset)
        } catch {
            return nil
        }

        var result = initial
        var previousUsage = initial.usage
        var carry = Data()
        var searchedThrough = 0
        var discardingLargeResponse = false
        // Only bytes ending in a newline are safe to checkpoint. Codex can still be
        // writing the final JSON object while we read an active rollout; advancing to
        // the physical EOF would make the remainder of that object unparseable later.
        var parsedBytes = fromOffset
        var discardedLineBytes: UInt64 = 0
        let fractionalDateFormatter = ISO8601DateFormatter()
        fractionalDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wholeSecondDateFormatter = ISO8601DateFormatter()

        while true {
            if shouldCancel() { return nil }
            let chunk = (try? handle.read(upToCount: 1_048_576)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            var chunkStart = chunk.startIndex

            while chunkStart < chunk.endIndex {
                if discardingLargeResponse {
                    guard let newline = chunk[chunkStart...].firstIndex(of: 0x0A) else {
                        discardedLineBytes += UInt64(chunk.distance(from: chunkStart, to: chunk.endIndex))
                        break
                    }
                    discardedLineBytes += UInt64(chunk.distance(from: chunkStart, to: newline) + 1)
                    parsedBytes += discardedLineBytes
                    discardedLineBytes = 0
                    discardingLargeResponse = false
                    chunkStart = chunk.index(after: newline)
                    continue
                }

                carry.append(contentsOf: chunk[chunkStart...])
                var lineStart = carry.startIndex
                var searchStart = carry.index(carry.startIndex, offsetBy: min(searchedThrough, carry.count))
                while searchStart < carry.endIndex,
                      let newline = carry[searchStart...].firstIndex(of: 0x0A) {
                    if shouldCancel() { return nil }
                    let line = Data(carry[lineStart..<newline])
                    autoreleasepool {
                        parseLine(
                            line,
                            result: &result,
                            previousUsage: &previousUsage,
                            fractionalDateFormatter: fractionalDateFormatter,
                            wholeSecondDateFormatter: wholeSecondDateFormatter
                        )
                    }
                    parsedBytes += UInt64(carry.distance(from: lineStart, to: newline) + 1)
                    lineStart = carry.index(after: newline)
                    searchStart = lineStart
                }
                if lineStart > carry.startIndex {
                    carry.removeSubrange(carry.startIndex..<lineStart)
                }
                searchedThrough = carry.count

                // Tool results can be hundreds of megabytes on one JSONL line. Once
                // its type is known, count a tool call if needed and discard the rest
                // of that line instead of retaining and rescanning it for every chunk.
                if carry.count >= 4_096,
                   carry.prefix(4_096).range(of: responseItemMarker) != nil {
                    parseLine(
                        Data(carry.prefix(4_096)),
                        result: &result,
                        previousUsage: &previousUsage,
                        fractionalDateFormatter: fractionalDateFormatter,
                        wholeSecondDateFormatter: wholeSecondDateFormatter
                    )
                    discardedLineBytes = UInt64(carry.count)
                    carry.removeAll(keepingCapacity: true)
                    searchedThrough = 0
                    discardingLargeResponse = true
                }
                break
            }
        }
        // Deliberately retain no result from an unterminated final line. The returned
        // offset points before it, so a later incremental pass reads the whole record.
        return ParseResult(enrichment: result, parsedBytes: parsedBytes)
    }

    private static func parseLine(
        _ data: Data,
        result: inout RolloutEnrichment,
        previousUsage: inout TokenUsage,
        fractionalDateFormatter: ISO8601DateFormatter,
        wholeSecondDateFormatter: ISO8601DateFormatter
    ) {
        // Rollouts contain large message and tool-result payloads that have no metric
        // value. Reject them as bytes before asking JSONSerialization to allocate a
        // complete Foundation object graph.
        let header = data.prefix(4_096)
        if header.range(of: responseItemMarker) != nil {
            if header.range(of: functionCallMarker) != nil || header.range(of: customToolCallMarker) != nil {
                result.toolCalls += 1
            }
            return
        }
        let isEventMessage = header.range(of: eventMessageMarker) != nil
        guard isEventMessage || header.range(of: turnContextMarker) != nil else { return }
        if isEventMessage {
            if header.range(of: userMessageMarker) != nil {
                result.userMessages += 1
                return
            }
            guard header.range(of: tokenCountMarker) != nil
                    || header.range(of: taskCompleteMarker) != nil
                    || header.range(of: turnAbortedMarker) != nil else { return }
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        let payload = object["payload"] as? [String: Any] ?? [:]
        let timestamp = (object["timestamp"] as? String).flatMap {
            fractionalDateFormatter.date(from: $0) ?? wholeSecondDateFormatter.date(from: $0)
        } ?? Date()

        if type == "turn_context" {
            result.model = payload["model"] as? String ?? result.model
            result.reasoningEffort = payload["effort"] as? String ?? result.reasoningEffort
            return
        }
        guard type == "event_msg", let event = payload["type"] as? String else { return }
        switch event {
        case "token_count":
            guard let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any] else { return }
            let usage = tokenUsage(total)
            let delta = usage.total >= previousUsage.total ? usage - previousUsage : usage
            let model = string(info["model"])
                ?? string(info["model_name"])
                ?? string(payload["model"])
                ?? string(payload["model_name"])
                ?? result.model
            if delta.total > 0 {
                result.usageEvents.append(.init(date: timestamp, usage: delta, model: model))
            }
            previousUsage = usage
            result.usage = usage
        case "task_complete":
            let completedAt = number(payload["completed_at"]).map { Date(timeIntervalSince1970: $0) } ?? timestamp
            let duration = number(payload["duration_ms"]).map { $0 / 1_000 } ?? 0
            let ttft = number(payload["time_to_first_token_ms"]).map { $0 / 1_000 }
            result.turns.append(.init(completedAt: completedAt, duration: duration, timeToFirstToken: ttft, completed: true))
        case "turn_aborted":
            result.abortedTurns += 1
            result.turns.append(.init(completedAt: timestamp, duration: 0, timeToFirstToken: nil, completed: false))
        default:
            break
        }
    }

    private static func tokenUsage(_ value: [String: Any]) -> TokenUsage {
        .init(
            input: integer(value["input_tokens"]),
            cachedInput: integer(value["cached_input_tokens"]),
            cacheWriteInput: integer(value["cache_write_input_tokens"]),
            output: integer(value["output_tokens"]),
            reasoningOutput: integer(value["reasoning_output_tokens"]),
            total: integer(value["total_tokens"])
        )
    }

    private static func integer(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) ?? 0 }
        return 0
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }
}

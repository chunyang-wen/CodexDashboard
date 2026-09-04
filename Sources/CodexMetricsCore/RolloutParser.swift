import Foundation

/// Active rollout files are appended frequently while a turn is streaming. The
/// full historical session archive waits for a short quiet period to avoid large
/// write amplification; compact parser checkpoints may advance incrementally.
enum MetricsPersistencePolicy {
    static let activeRolloutQuietPeriod: TimeInterval = 120
}

struct RolloutEnrichment: Codable, Sendable {
    var parserVersion: Int?
    var usage: TokenUsage = .zero
    var usageEvents: [UsageEvent] = []
    var turns: [TurnMetric] = []
    var model: String?
    var reasoningEffort: String?
    var serviceTier: String?
    var originator: String?
    var toolCalls = 0
    var toolCallEvents: [ToolCallEvent] = []
    var skillCallEvents: [SkillCallEvent] = []
    var userMessages = 0
    var abortedTurns = 0
    var subscription: SubscriptionSnapshot?
}

struct CachedRollout: Codable, Sendable {
    // v11 records the active service tier on token and attribution events.
    static let currentParserVersion = 11

    let fileSize: Int64
    let modifiedAt: Date
    let enrichment: RolloutEnrichment
    let deviceID: UInt64?
    let fileID: UInt64?
    let boundaryHash: UInt64?
    let parserVersion: Int?

    init(
        fileSize: Int64,
        modifiedAt: Date,
        enrichment: RolloutEnrichment,
        deviceID: UInt64? = nil,
        fileID: UInt64? = nil,
        boundaryHash: UInt64? = nil,
        parserVersion: Int? = CachedRollout.currentParserVersion
    ) {
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.enrichment = enrichment
        self.deviceID = deviceID
        self.fileID = fileID
        self.boundaryHash = boundaryHash
        self.parserVersion = parserVersion
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
        // v5 adds tool names and token attribution. Older cache entries only kept
        // the final session model and cannot price sessions that switched models.
        url = directory.appendingPathComponent("rollouts-v5.json")
        database = try? MetricsDatabase(userHome: home)
        if database == nil {
            if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String: CachedRollout].self, from: data) {
                entries = decoded
            } else {
                entries = [:]
            }
        } else {
            entries = [:]
            if FileManager.default.fileExists(atPath: url.path),
               let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([String: CachedRollout].self, from: data) {
                for (path, cached) in decoded where database?.rollout(for: path) == nil {
                    try? database?.storeRollout(cached, for: path)
                }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func lookup(_ path: String) -> Lookup {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return .miss }
        let cached = database?.rollout(for: path) ?? entries[path]
        guard let cached else { return .miss }
        guard cached.parserVersion == CachedRollout.currentParserVersion else { return .miss }
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
        // This is only the compact parser checkpoint: it contains parsed metric
        // values and an offset, never rollout content. Persist it even while the
        // file is active so the next refresh resumes from this pass instead of
        // rescanning the entire active tail. The larger historical session blob
        // still observes MetricsPersistencePolicy.activeRolloutQuietPeriod.
        var versionedEnrichment = enrichment
        versionedEnrichment.parserVersion = CachedRollout.currentParserVersion
        let cached = CachedRollout(
            fileSize: Int64(clamping: parsedBytes),
            modifiedAt: modified,
            enrichment: versionedEnrichment,
            deviceID: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            fileID: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            boundaryHash: Self.boundaryHash(path: path, through: Int64(clamping: parsedBytes)),
            parserVersion: CachedRollout.currentParserVersion
        )
        if let database {
            try? database.storeRollout(cached, for: path)
        } else {
            entries[path] = cached
        }
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
    private static let metricHeaderLimit = 262_144
    struct ParseResult: Sendable {
        let enrichment: RolloutEnrichment
        let parsedBytes: UInt64
    }

    private static let eventMessageMarker = Data(#""type":"event_msg""#.utf8)
    private static let sessionMetaMarker = Data(#""type":"session_meta""#.utf8)
    private static let turnContextMarker = Data(#""type":"turn_context""#.utf8)
    private static let responseItemMarker = Data(#""type":"response_item""#.utf8)
    private static let tokenCountMarker = Data(#""type":"token_count""#.utf8)
    private static let taskCompleteMarker = Data(#""type":"task_complete""#.utf8)
    private static let turnAbortedMarker = Data(#""type":"turn_aborted""#.utf8)
    private static let userMessageMarker = Data(#""type":"user_message""#.utf8)
    private static let threadSettingsMarker = Data(#""type":"thread_settings_applied""#.utf8)
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
        var pendingToolIndices = result.toolCallEvents.indices.filter {
            result.toolCallEvents[$0].attributedUsage.total == 0
        }
        var pendingSkillIndices = result.skillCallEvents.indices.filter {
            result.skillCallEvents[$0].attributedUsage.total == 0
        }
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
                            pendingToolIndices: &pendingToolIndices,
                            pendingSkillIndices: &pendingSkillIndices,
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
                if carry.count >= metricHeaderLimit,
                   carry.prefix(metricHeaderLimit).range(of: responseItemMarker) != nil {
                    parseLine(
                        Data(carry.prefix(metricHeaderLimit)),
                        result: &result,
                        previousUsage: &previousUsage,
                        pendingToolIndices: &pendingToolIndices,
                        pendingSkillIndices: &pendingSkillIndices,
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
        pendingToolIndices: inout [Int],
        pendingSkillIndices: inout [Int],
        fractionalDateFormatter: ISO8601DateFormatter,
        wholeSecondDateFormatter: ISO8601DateFormatter
    ) {
        // Rollouts contain large message and tool-result payloads that have no metric
        // value. Reject them as bytes before asking JSONSerialization to allocate a
        // complete Foundation object graph.
        let header = data.prefix(metricHeaderLimit)
        if header.range(of: sessionMetaMarker) != nil {
            result.originator = extractedString(named: "originator", from: header) ?? result.originator
            return
        }
        if header.range(of: responseItemMarker) != nil {
            if header.range(of: functionCallMarker) != nil || header.range(of: customToolCallMarker) != nil {
                result.toolCalls += 1
                let timestamp = extractedString(named: "timestamp", from: header).flatMap {
                    fractionalDateFormatter.date(from: $0) ?? wholeSecondDateFormatter.date(from: $0)
                } ?? Date()
                let outerName = extractedString(named: "name", from: header) ?? "Unknown tool"
                let input = toolInput(from: data)
                let name = displayToolName(outerName: outerName, input: input)
                result.toolCallEvents.append(.init(date: timestamp, name: name, model: result.model, serviceTier: result.serviceTier))
                pendingToolIndices.append(result.toolCallEvents.index(before: result.toolCallEvents.endIndex))
                for skill in skillNames(outerName: outerName, input: input) {
                    result.skillCallEvents.append(.init(date: timestamp, name: skill, model: result.model, serviceTier: result.serviceTier))
                    pendingSkillIndices.append(result.skillCallEvents.index(before: result.skillCallEvents.endIndex))
                }
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
                    || header.range(of: turnAbortedMarker) != nil
                    || header.range(of: threadSettingsMarker) != nil else { return }
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
            result.serviceTier = payload["service_tier"] as? String ?? result.serviceTier
            return
        }
        guard type == "event_msg", let event = payload["type"] as? String else { return }
        switch event {
        case "thread_settings_applied":
            guard let settings = payload["thread_settings"] as? [String: Any] else { return }
            result.model = string(settings["model"]) ?? result.model
            result.reasoningEffort = string(settings["reasoning_effort"]) ?? result.reasoningEffort
            result.serviceTier = string(settings["service_tier"]) ?? result.serviceTier
        case "token_count":
            if let limits = payload["rate_limits"] as? [String: Any] {
                if let candidate = SubscriptionReader.snapshot(from: limits, observedAt: timestamp),
                   result.subscription.map({ $0.observedAt < candidate.observedAt }) ?? true {
                    result.subscription = candidate
                }
            }
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
                result.usageEvents.append(.init(date: timestamp, usage: delta, model: model, serviceTier: result.serviceTier))
                attribute(delta, to: pendingToolIndices, model: model, serviceTier: result.serviceTier, events: &result.toolCallEvents)
                attributeSkills(delta, to: pendingSkillIndices, model: model, serviceTier: result.serviceTier, events: &result.skillCallEvents)
                pendingToolIndices.removeAll(keepingCapacity: true)
                pendingSkillIndices.removeAll(keepingCapacity: true)
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

    private static func extractedString(named key: String, from data: Data.SubSequence) -> String? {
        data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> String? in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let count = rawBuffer.count
            let keyBytes = Array("\"\(key)\":\"".utf8)
            let keyCount = keyBytes.count
            guard count >= keyCount else { return nil }

            var startOffset: Int?
            for i in 0...(count - keyCount) {
                var match = true
                for j in 0..<keyCount {
                    if baseAddress[i + j] != keyBytes[j] {
                        match = false
                        break
                    }
                }
                if match {
                    startOffset = i + keyCount
                    break
                }
            }
            guard let start = startOffset else { return nil }
            var index = start
            var value: [UInt8] = []
            value.reserveCapacity(64)
            var escaped = false
            while index < count {
                let byte = baseAddress[index]
                if escaped {
                    value.append(byte)
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    return String(decoding: value, as: UTF8.self)
                } else {
                    value.append(byte)
                }
                index += 1
            }
            return nil
        }
    }

    /// `exec` is a JavaScript orchestration envelope. Surface the operations it
    /// invokes while retaining the outer name so one envelope remains one call.
    private static func toolInput(from data: Data) -> String? {
        if let input = extractedString(named: "input", from: data.prefix(metricHeaderLimit)) {
            return input
        }
        if let arguments = extractedString(named: "arguments", from: data.prefix(metricHeaderLimit)) {
            return arguments
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return nil }
        return payload["input"] as? String ?? payload["arguments"] as? String
    }

    private static func displayToolName(outerName: String, input: String?) -> String {
        guard outerName == "exec" || outerName.hasSuffix(".exec") else { return outerName }
        guard let input else { return outerName }
        let nested = nestedToolCalls(from: input).map(\.name).reduce(into: [String]()) { names, name in
            if !names.contains(name) { names.append(name) }
        }
        guard !nested.isEmpty else { return outerName }
        return "\(outerName) → \(nested.joined(separator: " + "))"
    }

    private struct NestedToolCall {
        let name: String
        let arguments: String
    }

    private static func nestedToolCalls(from input: String) -> [NestedToolCall] {
        let bytes = Array(input.utf8)
        let marker = Array("tools.".utf8)
        var nested: [NestedToolCall] = []
        var index = 0
        var quote: UInt8?
        var escaped = false
        var lineComment = false
        var blockComment = false
        while index + marker.count < bytes.count {
            let byte = bytes[index]
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0
            if lineComment {
                if byte == 0x0A { lineComment = false }
                index += 1
                continue
            }
            if blockComment {
                if byte == 0x2A, next == 0x2F { blockComment = false; index += 2 } else { index += 1 }
                continue
            }
            if let activeQuote = quote {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == activeQuote { quote = nil }
                index += 1
                continue
            }
            if byte == 0x22 || byte == 0x27 || byte == 0x60 { quote = byte; index += 1; continue }
            if byte == 0x2F, next == 0x2F { lineComment = true; index += 2; continue }
            if byte == 0x2F, next == 0x2A { blockComment = true; index += 2; continue }
            guard bytes[index..<(index + marker.count)].elementsEqual(marker) else {
                index += 1
                continue
            }
            var end = index + marker.count
            while end < bytes.count {
                let byte = bytes[end]
                let isIdentifier = (byte >= 0x30 && byte <= 0x39)
                    || (byte >= 0x41 && byte <= 0x5A)
                    || (byte >= 0x61 && byte <= 0x7A)
                    || byte == 0x5F
                if !isIdentifier { break }
                end += 1
            }
            var callStart = end
            while callStart < bytes.count, bytes[callStart] == 0x20 || bytes[callStart] == 0x09 {
                callStart += 1
            }
            if end > index + marker.count,
               callStart < bytes.count,
               bytes[callStart] == 0x28,
               let operation = String(bytes: bytes[(index + marker.count)..<end], encoding: .utf8),
               operation.contains("_") || operation == "wait" {
                let argumentEnd = matchingCallEnd(in: bytes, openingAt: callStart)
                let arguments = String(bytes: bytes[(callStart + 1)..<argumentEnd], encoding: .utf8) ?? ""
                nested.append(.init(name: operation, arguments: arguments))
            }
            index = max(end, index + 1)
        }
        return nested
    }

    private static func matchingCallEnd(in bytes: [UInt8], openingAt start: Int) -> Int {
        var depth = 1
        var index = start + 1
        var quote: UInt8?
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if let activeQuote = quote {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == activeQuote { quote = nil }
            } else if byte == 0x22 || byte == 0x27 || byte == 0x60 {
                quote = byte
            } else if byte == 0x28 {
                depth += 1
            } else if byte == 0x29 {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return bytes.count
    }

    /// Skill use has no dedicated rollout event. Reading `.../<name>/SKILL.md`
    /// is the reliable activation signal mandated by the Codex skill workflow.
    private static func skillNames(outerName: String, input: String?) -> [String] {
        guard let input else { return [] }
        let text: String
        if outerName == "exec" {
            text = nestedToolCalls(from: input)
                .filter { $0.name == "exec_command" }
                .map(\.arguments)
                .joined(separator: "\n")
        } else if outerName.hasSuffix(".exec") {
            text = input
        } else {
            return []
        }
        let marker = "/SKILL.md"
        var names: [String] = []
        var searchStart = text.startIndex
        while let markerRange = text.range(of: marker, range: searchStart..<text.endIndex) {
            let prefix = text[..<markerRange.lowerBound]
            if let slash = prefix.lastIndex(of: "/") {
                let name = String(prefix[prefix.index(after: slash)...])
                if !name.isEmpty, !names.contains(name) { names.append(name) }
            }
            searchStart = markerRange.upperBound
        }
        return names
    }

    private static func attribute(
        _ usage: TokenUsage,
        to indices: [Int],
        model: String?,
        serviceTier: String?,
        events: inout [ToolCallEvent]
    ) {
        guard !indices.isEmpty else { return }
        for (position, index) in indices.enumerated() {
            events[index] = ToolCallEvent(
                date: events[index].date,
                name: events[index].name,
                model: events[index].model ?? model,
                serviceTier: events[index].serviceTier ?? serviceTier,
                attributedUsage: split(usage, count: indices.count, index: position)
            )
        }
    }

    private static func attributeSkills(
        _ usage: TokenUsage,
        to indices: [Int],
        model: String?,
        serviceTier: String?,
        events: inout [SkillCallEvent]
    ) {
        guard !indices.isEmpty else { return }
        for (position, index) in indices.enumerated() {
            events[index] = SkillCallEvent(
                date: events[index].date,
                name: events[index].name,
                model: events[index].model ?? model,
                serviceTier: events[index].serviceTier ?? serviceTier,
                attributedUsage: split(usage, count: indices.count, index: position)
            )
        }
    }

    private static func split(_ usage: TokenUsage, count: Int, index: Int) -> TokenUsage {
        func part(_ value: Int64) -> Int64 {
            let divisor = Int64(count)
            return value / divisor + (Int64(index) < value % divisor ? 1 : 0)
        }
        return TokenUsage(
            input: part(usage.input),
            cachedInput: part(usage.cachedInput),
            cacheWriteInput: part(usage.cacheWriteInput),
            output: part(usage.output),
            reasoningOutput: part(usage.reasoningOutput),
            total: part(usage.total)
        )
    }
}

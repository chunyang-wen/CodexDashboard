import Foundation

public enum ConversationDirection: String, Codable, Hashable, Sendable {
    case sent = "Sent"
    case received = "Received"
}

public enum ConversationItemKind: String, Codable, Hashable, Sendable {
    case instruction
    case userMessage
    case assistantMessage
    case toolCall
    case toolResult
    case reasoning
}

public struct ConversationItem: Identifiable, Codable, Hashable, Sendable {
    public let id: Int
    public let date: Date?
    public let direction: ConversationDirection
    public let kind: ConversationItemKind
    public let title: String
    public let body: String
    public let callID: String?
    public let rawJSON: String
    public let rawWasTruncated: Bool

    public init(
        id: Int,
        date: Date?,
        direction: ConversationDirection,
        kind: ConversationItemKind,
        title: String,
        body: String,
        callID: String? = nil,
        rawJSON: String,
        rawWasTruncated: Bool = false
    ) {
        self.id = id
        self.date = date
        self.direction = direction
        self.kind = kind
        self.title = title
        self.body = body
        self.callID = callID
        self.rawJSON = rawJSON
        self.rawWasTruncated = rawWasTruncated
    }

    public var prettyRawJSON: String {
        guard let data = rawJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else { return rawJSON }
        return text
    }

    public var redactedBody: String { ConversationRedactor.redact(body) }
    public var redactedRawJSON: String { ConversationRedactor.redact(prettyRawJSON) }
}

public struct ConversationTranscript: Sendable {
    public let items: [ConversationItem]
    public let omittedOversizedRecords: Int

    public init(items: [ConversationItem], omittedOversizedRecords: Int = 0) {
        self.items = items
        self.omittedOversizedRecords = omittedOversizedRecords
    }
}

public enum ConversationParserError: LocalizedError {
    case missingRollout
    case unreadableRollout

    public var errorDescription: String? {
        switch self {
        case .missingRollout: "The original rollout is no longer available. Conversation text is not kept in dashboard history."
        case .unreadableRollout: "The rollout could not be read."
        }
    }
}

/// Reads conversation payloads directly from one rollout. Nothing returned here is
/// written to the metrics cache or historical database.
public enum ConversationParser {
    private static let maximumRecordBytes = 2_000_000

    public static func load(path: String, shouldCancel: () -> Bool = { false }) throws -> ConversationTranscript {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            throw ConversationParserError.missingRollout
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw ConversationParserError.unreadableRollout
        }
        defer { try? handle.close() }

        var candidates: [Candidate] = []
        var carry = Data()
        var omitted = 0
        var sequence = 0
        var discardingOversizedRecord = false
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()

        while !shouldCancel() {
            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            var incoming = chunk
            if discardingOversizedRecord {
                guard let newline = incoming.firstIndex(of: 0x0A) else { continue }
                incoming = Data(incoming[incoming.index(after: newline)...])
                discardingOversizedRecord = false
            }
            carry.append(incoming)
            while let newline = carry.firstIndex(of: 0x0A) {
                let line = Data(carry[..<newline])
                carry.removeSubrange(...newline)
                defer { sequence += 1 }
                if line.count > maximumRecordBytes {
                    omitted += 1
                    continue
                }
                if let candidate = parse(line, sequence: sequence, fractional: fractional, whole: whole) {
                    candidates.append(candidate)
                }
            }
            // Do not retain an unbounded unterminated or malformed record.
            if carry.count > maximumRecordBytes {
                carry.removeAll(keepingCapacity: true)
                omitted += 1
                discardingOversizedRecord = true
            }
        }

        if shouldCancel() { throw CancellationError() }

        let filtered = candidates.filter { candidate in
            guard candidate.isFallback, let role = candidate.messageRole else { return true }
            return !candidates.contains { canonical in
                guard !canonical.isFallback,
                      canonical.messageRole == role,
                      canonical.body == candidate.body else { return false }
                switch (canonical.date, candidate.date) {
                case (.some(let left), .some(let right)):
                    return abs(left.timeIntervalSince(right)) < 1
                default:
                    return true
                }
            }
        }
        let items = filtered.enumerated().map { index, candidate in
            ConversationItem(
                id: index,
                date: candidate.date,
                direction: candidate.direction,
                kind: candidate.kind,
                title: candidate.title,
                body: candidate.body,
                callID: candidate.callID,
                rawJSON: candidate.rawJSON
            )
        }
        return ConversationTranscript(items: items, omittedOversizedRecords: omitted)
    }

    private struct Candidate {
        let sequence: Int
        let date: Date?
        let direction: ConversationDirection
        let kind: ConversationItemKind
        let title: String
        let body: String
        let callID: String?
        let rawJSON: String
        let messageRole: String?
        let isFallback: Bool
    }

    private static func parse(
        _ data: Data,
        sequence: Int,
        fractional: ISO8601DateFormatter,
        whole: ISO8601DateFormatter
    ) -> Candidate? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outerType = object["type"] as? String,
              let payload = object["payload"] as? [String: Any],
              let raw = String(data: data, encoding: .utf8) else { return nil }
        let date = (object["timestamp"] as? String).flatMap { fractional.date(from: $0) ?? whole.date(from: $0) }
        let payloadType = payload["type"] as? String ?? ""

        if outerType == "response_item" {
            switch payloadType {
            case "message":
                let role = payload["role"] as? String ?? "unknown"
                let body = messageText(payload["content"])
                guard !body.isEmpty else { return nil }
                let sent = role == "user" || role == "developer" || role == "system"
                return Candidate(
                    sequence: sequence, date: date,
                    direction: sent ? .sent : .received,
                    kind: role == "user" ? .userMessage : (role == "assistant" ? .assistantMessage : .instruction),
                    title: role.capitalized, body: body, callID: nil, rawJSON: raw,
                    messageRole: role, isFallback: false
                )
            case "function_call", "custom_tool_call":
                let name = payload["name"] as? String ?? "Unknown tool"
                let input = (payload["arguments"] as? String) ?? (payload["input"] as? String) ?? ""
                return Candidate(
                    sequence: sequence, date: date, direction: .received, kind: .toolCall,
                    title: "Tool call · \(name)", body: formattedJSON(input),
                    callID: payload["call_id"] as? String, rawJSON: raw,
                    messageRole: nil, isFallback: false
                )
            case "function_call_output", "custom_tool_call_output":
                let output = stringValue(payload["output"] ?? payload["content"])
                return Candidate(
                    sequence: sequence, date: date, direction: .sent, kind: .toolResult,
                    title: "Tool result", body: formattedJSON(output),
                    callID: payload["call_id"] as? String, rawJSON: raw,
                    messageRole: nil, isFallback: false
                )
            case "reasoning":
                let summary = messageText(payload["summary"])
                let content = messageText(payload["content"])
                let presentation: (title: String, body: String)
                if !content.isEmpty {
                    presentation = ("Reasoning details", content)
                } else if !summary.isEmpty {
                    presentation = ("Reasoning summary", summary)
                } else {
                    presentation = (
                        "Reasoning context",
                        "Codex retained encrypted reasoning state for conversation continuity. This rollout does not include a readable summary."
                    )
                }
                return Candidate(
                    sequence: sequence, date: date, direction: .received, kind: .reasoning,
                    title: presentation.title,
                    body: presentation.body,
                    callID: nil, rawJSON: raw, messageRole: nil, isFallback: false
                )
            default:
                return nil
            }
        }

        // Older rollouts may only have event messages. They are used only when no
        // canonical response_item exists for that role, avoiding duplicate bubbles.
        guard outerType == "event_msg" else { return nil }
        switch payloadType {
        case "user_message":
            let body = stringValue(payload["message"])
            guard !body.isEmpty else { return nil }
            return Candidate(
                sequence: sequence, date: date, direction: .sent, kind: .userMessage,
                title: "User", body: body, callID: nil, rawJSON: raw,
                messageRole: "user", isFallback: true
            )
        case "agent_message":
            let body = stringValue(payload["message"])
            guard !body.isEmpty else { return nil }
            return Candidate(
                sequence: sequence, date: date, direction: .received, kind: .assistantMessage,
                title: "Assistant", body: body, callID: nil, rawJSON: raw,
                messageRole: "assistant", isFallback: true
            )
        default:
            return nil
        }
    }

    private static func messageText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let parts = value as? [Any] else { return "" }
        return parts.compactMap { part -> String? in
            if let text = part as? String { return text }
            guard let object = part as? [String: Any] else { return nil }
            if let text = object["text"] as? String { return text }
            if let url = object["image_url"] as? String { return "[Image: \(url)]" }
            if let path = object["path"] as? String { return "[Local image: \(path)]" }
            return nil
        }.joined(separator: "\n\n")
    }

    private static func stringValue(_ value: Any?) -> String {
        if let value = value as? String { return value }
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func formattedJSON(_ value: String) -> String {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return value }
        return String(data: pretty, encoding: .utf8) ?? value
    }
}

private enum ConversationRedactor {
    static func redact(_ input: String) -> String {
        var result = input
        let patterns = [
            #"(?i)([\"']?authorization[\"']?\s*[:=]\s*[\"']?\s*bearer\s+)[A-Za-z0-9._~+/=-]+"#,
            #"(?i)([\"']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|secret(?:[_-]access)?[_-]?key|private[_-]?key|password)[\"']?\s*[:=]\s*[\"']?)[^\"'\s,}]+"#,
            #"\b(?:sk|sess|pat)_[A-Za-z0-9_-]{16,}\b"#,
            #"\bsk-[A-Za-z0-9_-]{16,}\b"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            if pattern.contains("(?:api") || pattern.contains("authorization") {
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1•••REDACTED•••")
            } else {
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "•••REDACTED•••")
            }
        }
        return result
    }
}

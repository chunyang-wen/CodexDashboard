import Foundation

public enum CodexSourcePathChange: Equatable, Sendable {
    case rollout(String)
    case index
    case irrelevant
}

/// Classifies file-level notifications from the Codex data directory without
/// touching the filesystem. Rollouts are date-organized rather than project-
/// organized, so the SQLite index remains the source of project membership.
public struct CodexSourcePathClassifier: Sendable {
    private let sessionsPrefix: String
    private let databasePaths: [String]

    public init(codexHome: URL) {
        let home = codexHome.standardizedFileURL
        sessionsPrefix = home.appendingPathComponent("sessions", isDirectory: true).path + "/"
        databasePaths = [
            home.appendingPathComponent("state_5.sqlite").path,
            home.appendingPathComponent("sqlite/state_5.sqlite").path
        ]
    }

    public func classify(_ rawPath: String) -> CodexSourcePathChange {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        if path.hasPrefix(sessionsPrefix), path.hasSuffix(".jsonl") {
            return .rollout(path)
        }
        if databasePaths.contains(where: { path == $0 || path.hasPrefix($0 + "-") || path.hasPrefix($0 + ".") }) {
            return .index
        }
        return .irrelevant
    }
}

import CodexMetricsCore
import CoreServices
import Foundation

struct CodexSourceChangeBatch: Sendable {
    var rolloutPaths: Set<String>
    var indexChanged: Bool
    var requiresReconciliation: Bool
    var latestEventID: UInt64

    mutating func merge(_ other: CodexSourceChangeBatch) {
        rolloutPaths.formUnion(other.rolloutPaths)
        indexChanged = indexChanged || other.indexChanged
        requiresReconciliation = requiresReconciliation || other.requiresReconciliation
        latestEventID = max(latestEventID, other.latestEventID)
    }
}

enum CodexSourceWatcherError: LocalizedError {
    case unavailable
    case startFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: "The macOS filesystem event stream could not be created."
        case .startFailed: "The macOS filesystem event stream could not be started."
        }
    }
}

/// One recursive, file-level FSEvents subscription for the Codex data directory.
/// macOS owns the filesystem journal; the app creates no helper process and holds
/// no descriptor per rollout.
final class CodexSourceWatcher: @unchecked Sendable {
    let events: AsyncStream<CodexSourceChangeBatch>
    let startingEventID: UInt64

    private let continuation: AsyncStream<CodexSourceChangeBatch>.Continuation
    private let classifier: CodexSourcePathClassifier
    private let queue = DispatchQueue(label: "CodexDashboard.SourceWatcher", qos: .utility)
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    init(codexHome: URL, sinceEventID: UInt64?, latency: TimeInterval) throws {
        classifier = CodexSourcePathClassifier(codexHome: codexHome)
        startingEventID = sinceEventID ?? FSEventsGetCurrentEventId()

        var capturedContinuation: AsyncStream<CodexSourceChangeBatch>.Continuation?
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation in
            capturedContinuation = continuation
        }
        guard let capturedContinuation else { throw CodexSourceWatcherError.unavailable }
        continuation = capturedContinuation

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            nil,
            Self.callback,
            &context,
            [codexHome.standardizedFileURL.path] as CFArray,
            FSEventStreamEventId(startingEventID),
            max(0.25, latency),
            flags
        ) else {
            continuation.finish()
            throw CodexSourceWatcherError.unavailable
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            continuation.finish()
            throw CodexSourceWatcherError.startFailed
        }
    }

    deinit { stop() }

    func stop() {
        let stream = lock.withLock { () -> FSEventStreamRef? in
            defer { self.stream = nil }
            return self.stream
        }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        continuation.finish()
    }

    private func receive(
        paths: [String],
        flags: UnsafePointer<FSEventStreamEventFlags>,
        eventIDs: UnsafePointer<FSEventStreamEventId>
    ) {
        var batch = CodexSourceChangeBatch(
            rolloutPaths: [],
            indexChanged: false,
            requiresReconciliation: false,
            latestEventID: 0
        )
        let recoveryFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged
        )

        for index in paths.indices {
            batch.latestEventID = max(batch.latestEventID, UInt64(eventIDs[index]))
            if flags[index] & recoveryFlags != 0 {
                batch.requiresReconciliation = true
            }
            switch classifier.classify(paths[index]) {
            case .rollout(let path): batch.rolloutPaths.insert(path)
            case .index: batch.indexChanged = true
            case .irrelevant: break
            }
        }
        guard batch.latestEventID > 0,
              batch.requiresReconciliation || batch.indexChanged || !batch.rolloutPaths.isEmpty else { return }
        continuation.yield(batch)
    }

    private static let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, eventIDs in
        guard let info else { return }
        let watcher = Unmanaged<CodexSourceWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
        guard paths.count == count else { return }
        watcher.receive(paths: paths, flags: flags, eventIDs: eventIDs)
    }
}

import CodexMetricsCore
import CoreServices
import Foundation

struct CodexSourceChangeBatch: Sendable {
    var rolloutPaths: Set<String>
    var indexChanged: Bool
    var requiresReconciliation: Bool
    var latestEventID: UInt64

    /// A rollout file is the direct signal that a session was created or used.
    /// Index-only events can also be emitted for SQLite housekeeping while the
    /// user is idle, so they must not by themselves wake the metrics pipeline.
    var hasSessionActivity: Bool {
        requiresReconciliation || !rolloutPaths.isEmpty
    }

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
    /// A one-slot wake-up stream. The actual changes live in `pendingBatch` so
    /// bursts of filesystem events are merged instead of queued individually.
    let events: AsyncStream<Void>
    let startingEventID: UInt64

    private let continuation: AsyncStream<Void>.Continuation
    private let classifier: CodexSourcePathClassifier
    private let queue = DispatchQueue(label: "CodexDashboard.SourceWatcher", qos: .utility)
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var pendingBatch: CodexSourceChangeBatch?
    private var signalQueued = false

    init(codexHome: URL, sinceEventID: UInt64?, latency: TimeInterval) throws {
        classifier = CodexSourcePathClassifier(codexHome: codexHome)
        startingEventID = sinceEventID ?? FSEventsGetCurrentEventId()

        var capturedContinuation: AsyncStream<Void>.Continuation?
        events = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
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
            pendingBatch = nil
            signalQueued = false
            defer { self.stream = nil }
            return self.stream
        }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        continuation.finish()
    }

    /// Returns all changes accumulated since the previous wake-up. The lock
    /// also closes the race where a filesystem callback arrives while the
    /// consumer is taking the current batch.
    func takePendingBatch() -> CodexSourceChangeBatch? {
        lock.withLock {
            signalQueued = false
            defer { pendingBatch = nil }
            return pendingBatch
        }
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
            let classification = classifier.classify(paths[index])
            guard classification != .irrelevant else { continue }
            batch.latestEventID = max(batch.latestEventID, UInt64(eventIDs[index]))
            if flags[index] & recoveryFlags != 0 {
                batch.requiresReconciliation = true
            }
            switch classification {
            case .rollout(let path): batch.rolloutPaths.insert(path)
            case .index: batch.indexChanged = true
            case .irrelevant: break
            }
        }
        guard batch.requiresReconciliation || batch.indexChanged || !batch.rolloutPaths.isEmpty else { return }
        let shouldSignal = lock.withLock { () -> Bool in
            if var pendingBatch {
                pendingBatch.merge(batch)
                self.pendingBatch = pendingBatch
            } else {
                pendingBatch = batch
            }
            guard !signalQueued else { return false }
            signalQueued = true
            return true
        }
        if shouldSignal {
            continuation.yield(())
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, eventIDs in
        guard let info else { return }
        let watcher = Unmanaged<CodexSourceWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
        guard paths.count == count else { return }
        watcher.receive(paths: paths, flags: flags, eventIDs: eventIDs)
    }
}

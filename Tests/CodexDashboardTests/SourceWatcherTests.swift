@testable import CodexDashboard
import Foundation
import XCTest

final class SourceWatcherTests: XCTestCase {
    func testIndexOnlyBatchDoesNotCountAsSessionActivity() {
        let batch = CodexSourceChangeBatch(
            rolloutPaths: [],
            indexChanged: true,
            requiresReconciliation: false,
            latestEventID: 1
        )

        XCTAssertFalse(batch.hasSessionActivity)
    }

    func testRecoveryBatchCountsAsSessionActivity() {
        let batch = CodexSourceChangeBatch(
            rolloutPaths: [],
            indexChanged: false,
            requiresReconciliation: true,
            latestEventID: 1
        )

        XCTAssertTrue(batch.hasSessionActivity)
    }

    func testWatcherReportsRolloutAndIndexChanges() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = home.appendingPathComponent("sessions/2026/08/21", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let watcher = try CodexSourceWatcher(codexHome: home, sinceEventID: nil, latency: 0.1)
        defer { watcher.stop() }
        let rollout = sessions.appendingPathComponent("rollout-test.jsonl")
        let index = home.appendingPathComponent("state_5.sqlite")

        try Data("{}\n".utf8).write(to: rollout)
        try Data("sqlite".utf8).write(to: index)
        let batch = try await waitForChanges(from: watcher) {
            $0.indexChanged && $0.rolloutPaths.contains(rollout.path)
        }

        XCTAssertTrue(batch.indexChanged)
        XCTAssertTrue(batch.rolloutPaths.contains(rollout.path))
        XCTAssertGreaterThan(batch.latestEventID, watcher.startingEventID)
    }

    func testWatcherCoalescesEventsWhileConsumerIsPaused() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = home.appendingPathComponent("sessions/2026/08/21", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let watcher = try CodexSourceWatcher(codexHome: home, sinceEventID: nil, latency: 0.1)
        defer { watcher.stop() }
        let firstRollout = sessions.appendingPathComponent("rollout-first.jsonl")
        let secondRollout = sessions.appendingPathComponent("rollout-second.jsonl")
        let index = home.appendingPathComponent("state_5.sqlite")

        try Data("first\n".utf8).write(to: firstRollout)
        try Data("sqlite\n".utf8).write(to: index)
        try Data("second\n".utf8).write(to: secondRollout)

        // Let the producer run without a consumer. A bounded watcher should
        // expose one merged batch when the consumer starts again.
        try await Task.sleep(for: .seconds(1))
        var iterator = watcher.events.makeAsyncIterator()
        let signal: Void? = await iterator.next()
        XCTAssertNotNil(signal)
        let batch = try XCTUnwrap(watcher.takePendingBatch())

        XCTAssertTrue(batch.indexChanged)
        XCTAssertTrue(batch.rolloutPaths.contains(firstRollout.path))
        XCTAssertTrue(batch.rolloutPaths.contains(secondRollout.path))
    }

    func testWatcherReplaysChangesMadeWhileItWasStopped() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = home.appendingPathComponent("sessions/2026/08/21", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let rollout = sessions.appendingPathComponent("rollout-replay.jsonl")

        let firstWatcher = try CodexSourceWatcher(codexHome: home, sinceEventID: nil, latency: 0.1)
        try Data("first\n".utf8).write(to: rollout)
        let firstBatch = try await waitForChanges(from: firstWatcher) {
            $0.rolloutPaths.contains(rollout.path)
        }
        firstWatcher.stop()
        try await Task.sleep(for: .milliseconds(500))

        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("second\n".utf8))
        try handle.synchronize()
        try handle.close()
        try await Task.sleep(for: .seconds(1))

        let replayWatcher = try CodexSourceWatcher(
            codexHome: home,
            sinceEventID: firstBatch.latestEventID,
            latency: 0.1
        )
        defer { replayWatcher.stop() }
        let replayed = try await waitForChanges(from: replayWatcher) {
            $0.rolloutPaths.contains(rollout.path)
        }

        XCTAssertGreaterThan(replayed.latestEventID, firstBatch.latestEventID)
    }

    private func waitForChanges(
        from watcher: CodexSourceWatcher,
        matching predicate: @escaping @Sendable (CodexSourceChangeBatch) -> Bool
    ) async throws -> CodexSourceChangeBatch {
        let received = Task { () throws -> CodexSourceChangeBatch in
            var accumulated = CodexSourceChangeBatch(
                rolloutPaths: [], indexChanged: false,
                requiresReconciliation: false, latestEventID: 0
            )
            var iterator = watcher.events.makeAsyncIterator()
            while await iterator.next() != nil {
                if let batch = watcher.takePendingBatch() {
                    accumulated.merge(batch)
                    if predicate(accumulated) { return accumulated }
                }
            }
            throw CancellationError()
        }
        return try await withThrowingTaskGroup(of: CodexSourceChangeBatch.self) { group in
            group.addTask { try await received.value }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw CocoaError(.fileReadUnknown)
            }
            let result = try await group.next()!
            group.cancelAll()
            received.cancel()
            return result
        }
    }
}

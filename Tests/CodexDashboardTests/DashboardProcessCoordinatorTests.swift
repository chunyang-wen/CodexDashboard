@testable import CodexDashboard
import Foundation
import XCTest

@MainActor
final class DashboardProcessCoordinatorTests: XCTestCase {
    func testDashboardReadinessIsNotBlockedByExtraVisibleWindows() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let helperSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/CodexDashboardUI/HelperMain.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(helperSource.contains("window === dashboardWindow"))
        XCTAssertFalse(helperSource.contains("NSApp.windows.filter(\\.isVisible).count == 1"))
    }

    func testLifecycleUsesWorkspaceTerminationNotificationsAndNoHalfSecondPolls() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coordinatorSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/CodexDashboard/DashboardProcessCoordinator.swift"),
            encoding: .utf8
        )
        let helperSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/CodexDashboardUI/HelperMain.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(coordinatorSource.contains("NSWorkspace.didTerminateApplicationNotification"))
        XCTAssertTrue(coordinatorSource.contains("defaultHelperLivenessFallbackInterval: TimeInterval = 5"))
        XCTAssertFalse(coordinatorSource.contains("withTimeInterval: 0.5"))

        XCTAssertTrue(helperSource.contains("NSWorkspace.didTerminateApplicationNotification"))
        XCTAssertTrue(helperSource.contains("hostFallbackWatchdog"))
        XCTAssertTrue(helperSource.contains("withTimeInterval: 5"))
        XCTAssertFalse(helperSource.contains("withTimeInterval: 0.5"))
    }

    func testLaunchAndReadyHandshake() {
        let harness = Harness()
        harness.coordinator.requestDashboard()

        XCTAssertEqual(harness.coordinator.state, .launching)
        XCTAssertEqual(harness.runtime.launches.count, 1)
        let launch = harness.runtime.launches[0]
        XCTAssertEqual(launch.arguments.value(for: "--codex-dashboard-host-pid"), "4242")
        XCTAssertNotNil(launch.arguments.value(for: "--codex-dashboard-launch-token"))
        XCTAssertEqual(launch.arguments.value(for: "--codex-dashboard-generation"), "1")

        harness.runtime.completeLaunch(pid: 9001, arguments: launch.arguments)
        harness.bus.sendReady(token: launch.arguments.value(for: "--codex-dashboard-launch-token")!, helperPID: 9001, generation: 1)

        XCTAssertEqual(harness.coordinator.state, .ready)
        XCTAssertEqual(harness.coordinator.currentHelperPID, 9001)
        XCTAssertEqual(harness.runtime.activations, [9001])
    }

    func testCoordinatorRegistersExactlyOneLifecycleObserver() {
        let harness = Harness()
        _ = harness.coordinator

        XCTAssertEqual(harness.bus.observeCount, 1)
    }

    func testLaunchAndReadyUseIndependentTimeoutPhases() {
        let harness = Harness(launchTimeout: 10)
        harness.coordinator.requestDashboard()
        let launch = harness.runtime.launches[0]

        harness.runtime.completeLaunch(pid: 9001, arguments: launch.arguments)
        XCTAssertEqual(harness.scheduler.delays, [10, 10])

        harness.scheduler.fireNext()
        XCTAssertEqual(harness.coordinator.state, .launching)

        harness.scheduler.fireNext()
        XCTAssertEqual(harness.coordinator.state, .stopped)
        XCTAssertEqual(harness.runtime.terminations, [9001])
    }

    func testReadyRequestFocusesWithoutRelaunching() {
        let harness = Harness()
        harness.launchAndReady()

        harness.coordinator.requestDashboard()

        XCTAssertEqual(harness.runtime.launches.count, 1)
        XCTAssertEqual(harness.runtime.activations, [9001, 9001])
        XCTAssertEqual(harness.bus.messages.filter { $0.command == .focus }.count, 2)
    }

    func testHelperClosingMessageStopsHostCoordinatorForImmediateRelaunch() {
        let harness = Harness()
        harness.launchAndReady()

        harness.bus.sendHelperClosing(
            token: harness.coordinator.currentLaunchToken!,
            helperPID: 9001,
            generation: harness.coordinator.currentGeneration
        )

        XCTAssertEqual(harness.coordinator.state, .stopped)
        XCTAssertNil(harness.coordinator.currentHelperPID)
        harness.coordinator.requestDashboard()
        XCTAssertEqual(harness.runtime.launches.count, 2)
    }

    func testReadyHelperReceivesAuthenticatedLiveSettingsForCurrentPIDAndGeneration() {
        let defaultsName = "DashboardProcessCoordinatorTests.Settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set("/tmp/live-codex", forKey: DashboardPreferences.codexDataPathKey)
        defaults.set(15.0, forKey: DashboardPreferences.metricsRefreshIntervalKey)
        defaults.set(false, forKey: DashboardPreferences.weekStartsMondayKey)

        let harness = Harness(defaults: defaults)
        harness.launchAndReady()
        harness.coordinator.settingsChanged()

        let message = try! XCTUnwrap(harness.bus.messages.last)
        XCTAssertEqual(message.command, .settingsChanged)
        XCTAssertEqual(message.token, harness.coordinator.currentLaunchToken)
        XCTAssertEqual(message.hostPID, 4242)
        XCTAssertEqual(message.helperPID, 9001)
        XCTAssertEqual(message.generation, 1)
        XCTAssertEqual(message.codexDataPath, "/tmp/live-codex")
        XCTAssertEqual(message.refreshInterval, 15)
        XCTAssertEqual(message.weekStartsMonday, false)

    }

    func testAuthenticatedExternalHelperCommandsReachCallbackOnce() {
        let harness = Harness()
        harness.launchAndReady()
        var receivedCommands: [DashboardLifecycleCommand] = []
        harness.coordinator.helperCommandHandler = { command in
            receivedCommands.append(command)
        }

        let token = harness.coordinator.currentLaunchToken!
        let helperPID = harness.coordinator.currentHelperPID!
        let generation = harness.coordinator.currentGeneration
        let commands: [DashboardLifecycleCommand] = [.openSettings, .checkForUpdates, .quitProduct]
        for command in commands {
            harness.bus.send(DashboardLifecycleMessage(
                command: command,
                token: token,
                hostPID: 4242,
                helperPID: helperPID,
                generation: generation
            ))
        }

        XCTAssertEqual(receivedCommands, commands)
    }

    func testInvalidOrInternalHelperMessagesDoNotReachExternalCommandCallback() {
        let harness = Harness()
        harness.launchAndReady()
        var receivedCommands: [DashboardLifecycleCommand] = []
        harness.coordinator.helperCommandHandler = { command in
            receivedCommands.append(command)
        }

        let valid = DashboardLifecycleMessage(
            command: .openSettings,
            token: harness.coordinator.currentLaunchToken!,
            hostPID: 4242,
            helperPID: harness.coordinator.currentHelperPID!,
            generation: harness.coordinator.currentGeneration
        )
        for message in [
            DashboardLifecycleMessage(command: .openSettings, token: "stale-token", hostPID: valid.hostPID, helperPID: valid.helperPID, generation: valid.generation),
            DashboardLifecycleMessage(command: .checkForUpdates, token: valid.token, hostPID: valid.hostPID + 1, helperPID: valid.helperPID, generation: valid.generation),
            DashboardLifecycleMessage(command: .quitProduct, token: valid.token, hostPID: valid.hostPID, helperPID: valid.helperPID + 1, generation: valid.generation),
            DashboardLifecycleMessage(command: .openSettings, token: valid.token, hostPID: valid.hostPID, helperPID: valid.helperPID, generation: valid.generation + 1),
            DashboardLifecycleMessage(command: .ready, token: valid.token, hostPID: valid.hostPID, helperPID: valid.helperPID, generation: valid.generation),
            DashboardLifecycleMessage(command: .helperClosing, token: valid.token, hostPID: valid.hostPID, helperPID: valid.helperPID, generation: valid.generation)
        ] {
            harness.bus.send(message)
        }

        XCTAssertTrue(receivedCommands.isEmpty)
    }

    func testTenRapidRequestsProduceOneLaunch() {
        let harness = Harness()
        for _ in 0..<10 { harness.coordinator.requestDashboard() }

        XCTAssertEqual(harness.runtime.launches.count, 1)
        XCTAssertEqual(harness.coordinator.state, .launching)
    }

    func testTimeoutStopsAndAllowsRetry() {
        let harness = Harness()
        harness.coordinator.requestDashboard()
        let firstToken = harness.coordinator.currentLaunchToken

        harness.scheduler.fireNext()

        XCTAssertEqual(harness.coordinator.state, .stopped)
        XCTAssertNil(harness.coordinator.currentHelperPID)
        harness.coordinator.requestDashboard()
        XCTAssertEqual(harness.runtime.launches.count, 2)
        XCTAssertNotEqual(firstToken, harness.coordinator.currentLaunchToken)
    }

    func testLaunchFailureStopsAndAllowsRetry() {
        let harness = Harness()
        harness.coordinator.requestDashboard()
        harness.runtime.failLaunch(at: 0)

        XCTAssertEqual(harness.coordinator.state, .stopped)
        harness.coordinator.requestDashboard()
        XCTAssertEqual(harness.runtime.launches.count, 2)
        XCTAssertEqual(harness.runtime.launches[1].arguments.value(for: "--codex-dashboard-generation"), "2")
    }

    func testUntaggedLaunchEventCannotBindStalePIDToNewGeneration() {
        let harness = Harness()
        harness.coordinator.requestDashboard()
        harness.scheduler.fireNext()
        harness.coordinator.requestDashboard()

        harness.runtime.sendLaunch(pid: 9999, arguments: [])

        XCTAssertEqual(harness.coordinator.state, .launching)
        XCTAssertNil(harness.coordinator.currentHelperPID)
        let secondLaunch = harness.runtime.launches[1]
        harness.runtime.completeLaunch(at: 1, pid: 9002, arguments: secondLaunch.arguments)
        harness.bus.sendReady(token: secondLaunch.arguments.value(for: "--codex-dashboard-launch-token")!, helperPID: 9002, generation: 2)
        XCTAssertEqual(harness.coordinator.state, .ready)
        XCTAssertEqual(harness.coordinator.currentHelperPID, 9002)
    }

    func testLateLaunchSuccessAfterTimeoutIsTerminatedWithoutChangingState() {
        let harness = Harness()
        harness.coordinator.requestDashboard()
        let firstLaunch = harness.runtime.launches[0]
        harness.scheduler.fireNext()

        harness.runtime.completeLaunch(at: 0, pid: 9001, arguments: firstLaunch.arguments)

        XCTAssertEqual(harness.coordinator.state, .stopped)
        XCTAssertNil(harness.coordinator.currentHelperPID)
        XCTAssertEqual(harness.runtime.terminations, [9001])

        harness.coordinator.requestDashboard()
        let secondLaunch = harness.runtime.launches[1]
        harness.runtime.completeLaunch(at: 1, pid: 9001, arguments: secondLaunch.arguments)
        harness.runtime.completeLaunch(at: 0, pid: 9001, arguments: firstLaunch.arguments)

        XCTAssertEqual(harness.coordinator.state, .launching)
        XCTAssertEqual(harness.coordinator.currentHelperPID, 9001)
        XCTAssertEqual(harness.runtime.terminations, [9001])
    }

    func testStaleReadyAndTerminationAreIgnored() {
        let harness = Harness()
        harness.coordinator.requestDashboard()
        let firstLaunch = harness.runtime.launches[0]
        harness.runtime.completeLaunch(pid: 9001, arguments: firstLaunch.arguments)
        harness.bus.sendReady(token: firstLaunch.arguments.value(for: "--codex-dashboard-launch-token")!, helperPID: 9001, generation: 1)
        harness.coordinator.terminateForHostQuit()
        harness.runtime.sendTermination(pid: 9001, arguments: firstLaunch.arguments)

        harness.coordinator.requestDashboard()
        let secondLaunch = harness.runtime.launches[1]
        harness.bus.sendReady(token: firstLaunch.arguments.value(for: "--codex-dashboard-launch-token")!, helperPID: 9001, generation: 1)
        XCTAssertEqual(harness.coordinator.state, .launching)
        harness.runtime.completeLaunch(pid: 9002, arguments: secondLaunch.arguments)
        harness.runtime.sendTermination(pid: 9001, arguments: firstLaunch.arguments)
        XCTAssertEqual(harness.coordinator.currentHelperPID, 9002)
        harness.bus.sendReady(token: secondLaunch.arguments.value(for: "--codex-dashboard-launch-token")!, helperPID: 9002, generation: 2)
        XCTAssertEqual(harness.coordinator.state, .ready)
    }

    func testHelperCrashLeavesCoordinatorUsable() {
        let harness = Harness()
        harness.launchAndReady()
        harness.runtime.sendTermination(pid: 9001, arguments: harness.runtime.launches[0].arguments)

        XCTAssertEqual(harness.coordinator.state, .stopped)
        harness.coordinator.requestDashboard()
        XCTAssertEqual(harness.runtime.launches.count, 2)
    }

    func testCleanHelperTerminationAllowsImmediateRelaunch() {
        let harness = Harness()
        harness.launchAndReady()

        harness.runtime.sendTermination(pid: 9001, arguments: [])

        XCTAssertEqual(harness.coordinator.state, .stopped)
        XCTAssertNil(harness.coordinator.currentHelperPID)

        harness.coordinator.requestDashboard()

        XCTAssertEqual(harness.runtime.launches.count, 2)
        XCTAssertEqual(harness.coordinator.state, .launching)
        XCTAssertEqual(
            harness.runtime.launches[1].arguments.value(for: "--codex-dashboard-generation"),
            "2"
        )
    }

    func testTerminationIdentityAcceptsKnownPIDWithoutBundleURL() {
        let helperURL = URL(fileURLWithPath: "/tmp/CodexDashboardUI.app")

        XCTAssertTrue(dashboardTerminationMatchesHelper(
            processIdentifier: 9001,
            bundleURL: nil,
            launchDate: Date(timeIntervalSince1970: 100),
            helperURL: helperURL,
            knownHelperIdentities: [9001: DashboardProcessIdentity(
                pid: 9001,
                arguments: [],
                launchDate: Date(timeIntervalSince1970: 100)
            )]
        ))
        XCTAssertFalse(dashboardTerminationMatchesHelper(
            processIdentifier: 9002,
            bundleURL: nil,
            launchDate: nil,
            helperURL: helperURL,
            knownHelperIdentities: [9001: DashboardProcessIdentity(pid: 9001, arguments: [])]
        ))
    }

    func testStaleSamePIDTerminationDoesNotStopNewGeneration() {
        let harness = Harness()
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)

        harness.coordinator.requestDashboard()
        let firstLaunch = harness.runtime.launches[0]
        harness.runtime.completeLaunch(pid: 9001, arguments: firstLaunch.arguments, launchDate: firstDate)
        harness.bus.sendReady(token: firstLaunch.arguments.value(for: "--codex-dashboard-launch-token")!, helperPID: 9001, generation: 1)
        harness.runtime.sendTermination(pid: 9001, arguments: [], launchDate: firstDate)

        harness.coordinator.requestDashboard()
        let secondLaunch = harness.runtime.launches[1]
        harness.runtime.completeLaunch(at: 1, pid: 9001, arguments: secondLaunch.arguments, launchDate: secondDate)
        harness.bus.sendReady(token: secondLaunch.arguments.value(for: "--codex-dashboard-launch-token")!, helperPID: 9001, generation: 2)

        harness.runtime.sendTermination(pid: 9001, arguments: [], launchDate: firstDate)

        XCTAssertEqual(harness.coordinator.state, .ready)
        XCTAssertEqual(harness.coordinator.currentHelperPID, 9001)

        harness.runtime.sendTermination(pid: 9001, arguments: firstLaunch.arguments, launchDate: nil)

        XCTAssertEqual(harness.coordinator.state, .ready)

        harness.runtime.sendTermination(pid: 9001, arguments: [], launchDate: secondDate)
        XCTAssertEqual(harness.coordinator.state, .stopped)
    }

    func testHostQuitPostsBeforeTerminatingHelper() {
        let harness = Harness()
        harness.launchAndReady()
        var events: [String] = []
        harness.bus.onPost = { _ in events.append("post") }
        harness.runtime.onTerminate = { _ in
            events.append("terminate")
        }

        harness.coordinator.terminateForHostQuit()

        XCTAssertEqual(harness.coordinator.state, .terminating)
        XCTAssertEqual(events, ["post", "terminate"])
        XCTAssertEqual(harness.bus.messages.last?.command, .quitProduct)
        XCTAssertEqual(harness.runtime.terminations, [9001])
        harness.runtime.sendTermination(pid: 9001, arguments: harness.runtime.launches[0].arguments)
        XCTAssertEqual(harness.coordinator.state, .stopped)
    }

    func testHostQuitTerminationTimeoutStopsCoordinator() {
        let harness = Harness()
        harness.launchAndReady()

        harness.coordinator.terminateForHostQuit()
        harness.scheduler.fireLast()

        XCTAssertEqual(harness.runtime.terminations, [9001])
        XCTAssertEqual(harness.coordinator.state, .stopped)
        XCTAssertNil(harness.coordinator.currentHelperPID)
    }

    func testHostQuitCompletionWaitsForCoordinatorToStop() {
        let harness = Harness()
        harness.launchAndReady()
        var didComplete = false

        harness.coordinator.terminateForHostQuit {
            didComplete = true
        }

        XCTAssertFalse(didComplete)
        harness.scheduler.fireLast()
        XCTAssertTrue(didComplete)
        XCTAssertEqual(harness.coordinator.state, .stopped)
    }

    func testHelperProductQuitStartsHostTerminationOnlyAfterHelperStops() async {
        let gate = DashboardProductTerminationGate()
        var stopHelper: (@MainActor () -> Void)?
        var hostTerminationCount = 0
        let hostTermination = expectation(description: "host termination starts")

        gate.requestFromHelper(
            helperState: .ready,
            terminateHelper: { completion in
                stopHelper = completion
            },
            terminateHost: {
                hostTerminationCount += 1
                hostTermination.fulfill()
            }
        )

        XCTAssertEqual(gate.state, .waitingForHelper)
        XCTAssertEqual(hostTerminationCount, 0)
        stopHelper?()

        await fulfillment(of: [hostTermination], timeout: 1)
        XCTAssertEqual(gate.state, .terminating)
        XCTAssertEqual(hostTerminationCount, 1)
    }

    func testHelperProductQuitIsDeduplicatedWhileWaiting() async {
        let gate = DashboardProductTerminationGate()
        var stopHelper: (@MainActor () -> Void)?
        var stopRequests = 0
        var hostTerminationCount = 0
        let hostTermination = expectation(description: "host termination starts")

        let request = {
            gate.requestFromHelper(
                helperState: .ready,
                terminateHelper: { completion in
                    stopRequests += 1
                    stopHelper = completion
                },
                terminateHost: {
                    hostTerminationCount += 1
                    hostTermination.fulfill()
                }
            )
        }
        request()
        request()
        XCTAssertEqual(stopRequests, 1)

        stopHelper?()
        await fulfillment(of: [hostTermination], timeout: 1)
        XCTAssertEqual(hostTerminationCount, 1)
    }

    func testNormalHostQuitRepliesOnlyAfterHelperStops() async {
        let gate = DashboardProductTerminationGate()
        var stopHelper: (@MainActor () -> Void)?
        var didReply = false
        let replyExpectation = expectation(description: "termination reply")

        let result = gate.applicationShouldTerminate(
            helperState: .ready,
            terminateHelper: { completion in
                stopHelper = completion
            },
            reply: {
                didReply = true
                replyExpectation.fulfill()
            }
        )

        XCTAssertEqual(result, .terminateLater)
        XCTAssertFalse(didReply)
        stopHelper?()

        await fulfillment(of: [replyExpectation], timeout: 1)
        XCTAssertTrue(didReply)
        XCTAssertEqual(gate.state, .terminating)
    }

    func testHostAndHelperCommandChannelsCannotSelfEcho() {
        XCTAssertNotEqual(DashboardLifecycleChannel.hostToHelper, DashboardLifecycleChannel.helperToHost)
        XCTAssertNotEqual(DashboardLifecycleChannel.ready, DashboardLifecycleChannel.hostToHelper)
        XCTAssertNotEqual(DashboardLifecycleChannel.ready, DashboardLifecycleChannel.helperToHost)
    }

    func testInactiveHostDeliversAllHelperCommandsImmediatelyWithoutEcho() async {
        let center = FakeNotificationCenter()
        let bus = DistributedDashboardLifecycleBus(center: center)
        let expectedCommands: [DashboardLifecycleCommand] = [.openSettings, .checkForUpdates, .quitProduct]
        var receivedCommands: [DashboardLifecycleCommand] = []
        let expectation = expectation(description: "all helper-to-host commands delivered")
        expectation.expectedFulfillmentCount = expectedCommands.count
        let observation = bus.observe { message in
            guard expectedCommands.contains(message.command) else { return }
            receivedCommands.append(message.command)
            expectation.fulfill()
        }

        XCTAssertTrue(center.registrations.allSatisfy { $0.suspensionBehavior == .deliverImmediately })
        XCTAssertEqual(
            center.registrations.map(\.name),
            [DashboardLifecycleChannel.ready, DashboardLifecycleChannel.helperToHost]
        )

        center.isInactive = true
        for command in expectedCommands {
            center.post(
                name: DashboardLifecycleChannel.helperToHost,
                object: nil,
                userInfo: lifecycleUserInfo(command: command)
            )
        }

        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(receivedCommands, expectedCommands)

        bus.post(DashboardLifecycleMessage(
            command: .openSettings,
            token: "host-token",
            hostPID: 42,
            helperPID: 84,
            generation: 3
        ))
        XCTAssertEqual(
            center.posts.filter { $0.name == DashboardLifecycleChannel.hostToHelper }.map(\.name),
            [DashboardLifecycleChannel.hostToHelper]
        )
        _ = observation
    }

    func testSuccessfulRelaunchAfterCrashUsesNewGeneration() {
        let harness = Harness()
        harness.launchAndReady()
        harness.runtime.sendTermination(pid: 9001, arguments: harness.runtime.launches[0].arguments)
        harness.coordinator.requestDashboard()

        let launch = harness.runtime.launches[1]
        XCTAssertEqual(launch.arguments.value(for: "--codex-dashboard-generation"), "2")
        XCTAssertNotEqual(
            launch.arguments.value(for: "--codex-dashboard-launch-token"),
            harness.runtime.launches[0].arguments.value(for: "--codex-dashboard-launch-token")
        )
    }

    @MainActor
    private final class Harness {
        let runtime = FakeRuntime()
        let bus = FakeBus()
        let scheduler = FakeScheduler()
        let defaults: UserDefaults?
        let launchTimeout: TimeInterval
        lazy var coordinator = DashboardProcessCoordinator(
            helperURL: URL(fileURLWithPath: "/tmp/CodexDashboardUI.app"),
            hostPID: 4242,
            runtime: runtime,
            lifecycleBus: bus,
            scheduler: scheduler,
            launchTimeout: launchTimeout,
            preferences: defaults ?? DashboardPreferences.sharedDefaults(),
            codexDataPathProvider: {
                self.defaults?.string(forKey: DashboardPreferences.codexDataPathKey)
            }
        )

        init(defaults: UserDefaults? = nil, launchTimeout: TimeInterval = 5) {
            self.defaults = defaults
            self.launchTimeout = launchTimeout
        }

        func launchAndReady() {
            coordinator.requestDashboard()
            let launch = runtime.launches[0]
            runtime.completeLaunch(pid: 9001, arguments: launch.arguments)
            bus.sendReady(token: launch.arguments.value(for: "--codex-dashboard-launch-token")!, helperPID: 9001, generation: 1)
        }
    }

    private final class Token: NSObject {}

    private func lifecycleUserInfo(command: DashboardLifecycleCommand) -> [AnyHashable: Any] {
        [
            "command": command.rawValue,
            "launchToken": "helper-token",
            "hostPID": NSNumber(value: 42),
            "processID": NSNumber(value: 84),
            "generation": NSNumber(value: 3)
        ]
    }

    @MainActor
    private final class FakeNotificationCenter: DashboardLifecycleNotificationCenter {
        struct Registration {
            let observer: DistributedDashboardLifecycleObserver
            let selector: Selector
            let name: Notification.Name
            let suspensionBehavior: DistributedNotificationCenter.SuspensionBehavior
        }

        struct Post {
            let name: Notification.Name
            let userInfo: [AnyHashable: Any]?
        }

        var isInactive = false
        var registrations: [Registration] = []
        var posts: [Post] = []

        func addObserver(
            _ observer: DistributedDashboardLifecycleObserver,
            selector: Selector,
            name: Notification.Name,
            object: String?,
            suspensionBehavior: DistributedNotificationCenter.SuspensionBehavior
        ) {
            registrations.append(Registration(
                observer: observer,
                selector: selector,
                name: name,
                suspensionBehavior: suspensionBehavior
            ))
        }

        func removeObserver(_ observer: DistributedDashboardLifecycleObserver) {
            registrations.removeAll { $0.observer === observer }
        }

        func post(name: Notification.Name, object: String?, userInfo: [AnyHashable: Any]?) {
            posts.append(Post(name: name, userInfo: userInfo))
            guard isInactive else { return }
            let notification = Notification(name: name, object: object, userInfo: userInfo)
            registrations
                .filter { $0.name == name && $0.suspensionBehavior == .deliverImmediately }
                .forEach { registration in
                    if registration.selector == #selector(DistributedDashboardLifecycleObserver.receiveReady(_:)) {
                        registration.observer.receiveReady(notification)
                    } else if registration.selector == #selector(DistributedDashboardLifecycleObserver.receiveCommand(_:)) {
                        registration.observer.receiveCommand(notification)
                    }
                }
        }
    }

    @MainActor
    private final class FakeRuntime: DashboardProcessRuntime {
        struct Launch {
            let arguments: [String]
            let completion: @MainActor (Result<DashboardProcessIdentity, Error>) -> Void
        }

        var launches: [Launch] = []
        var activations: [Int32] = []
        var terminations: [Int32] = []
        var onTerminate: ((Int32) -> Void)?
        private var handler: (@MainActor (DashboardProcessRuntimeEvent) -> Void)?

        func launch(arguments: [String], completion: @escaping @MainActor (Result<DashboardProcessIdentity, Error>) -> Void) {
            launches.append(Launch(arguments: arguments, completion: completion))
        }

        func activate(pid: Int32) {
            activations.append(pid)
        }

        func terminate(pid: Int32) {
            terminations.append(pid)
            onTerminate?(pid)
        }

        @discardableResult
        func observe(_ handler: @escaping @MainActor (DashboardProcessRuntimeEvent) -> Void) -> AnyObject {
            self.handler = handler
            return Token()
        }

        func completeLaunch(pid: Int32, arguments: [String], launchDate: Date? = nil) {
            completeLaunch(at: launches.count - 1, pid: pid, arguments: arguments, launchDate: launchDate)
        }

        func completeLaunch(at index: Int, pid: Int32, arguments: [String], launchDate: Date? = nil) {
            launches[index].completion(.success(DashboardProcessIdentity(
                pid: pid,
                arguments: arguments,
                launchDate: launchDate
            )))
        }

        func failLaunch(at index: Int) {
            launches[index].completion(.failure(NSError(domain: "test", code: 1)))
        }

        func sendLaunch(pid: Int32, arguments: [String]) {
            handler?(.launched(pid: pid, arguments: arguments))
        }

        func sendTermination(pid: Int32, arguments: [String], launchDate: Date? = nil) {
            handler?(.terminated(pid: pid, arguments: arguments, launchDate: launchDate))
        }
    }

    @MainActor
    private final class FakeBus: DashboardLifecycleBus {
        var messages: [DashboardLifecycleMessage] = []
        var onPost: ((DashboardLifecycleMessage) -> Void)?
        private(set) var observeCount = 0
        private var handler: (@MainActor (DashboardLifecycleMessage) -> Void)?

        @discardableResult
        func observe(_ handler: @escaping @MainActor (DashboardLifecycleMessage) -> Void) -> AnyObject {
            observeCount += 1
            self.handler = handler
            return Token()
        }

        func post(_ message: DashboardLifecycleMessage) {
            messages.append(message)
            onPost?(message)
        }

        func send(_ message: DashboardLifecycleMessage) {
            handler?(message)
        }

        func sendReady(token: String, helperPID: Int32, generation: UInt64) {
            handler?(DashboardLifecycleMessage(
                command: .ready,
                token: token,
                hostPID: 4242,
                helperPID: helperPID,
                generation: generation
            ))
        }

        func sendHelperClosing(token: String, helperPID: Int32, generation: UInt64) {
            handler?(DashboardLifecycleMessage(
                command: .helperClosing,
                token: token,
                hostPID: 4242,
                helperPID: helperPID,
                generation: generation
            ))
        }

    }

    @MainActor
    private final class FakeScheduler: DashboardCoordinatorScheduler {
        private var actions: [@MainActor () -> Void] = []
        private(set) var delays: [TimeInterval] = []

        @discardableResult
        func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AnyObject {
            delays.append(delay)
            actions.append(action)
            return Token()
        }

        func fireNext() {
            actions.removeFirst()()
        }

        func fireLast() {
            actions.removeLast()()
        }
    }
}

private extension Array where Element == String {
    func value(for flag: String) -> String? {
        guard let index = firstIndex(of: flag), index + 1 < count else { return nil }
        return self[index + 1]
    }
}

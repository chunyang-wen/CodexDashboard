import AppKit
import Foundation

enum DashboardProcessState: Equatable {
    case stopped
    case launching
    case ready
    case terminating
}

enum DashboardLifecycleCommand: String, Sendable {
    case ready
    case helperClosing
    case focus
    case refreshMetrics
    case rebuildHistoryIndex
    case settingsChanged
    case openSettings
    case checkForUpdates
    case quitProduct
}

struct DashboardLifecycleMessage: Equatable, Sendable {
    let command: DashboardLifecycleCommand
    let token: String
    let hostPID: Int32
    let helperPID: Int32
    let generation: UInt64
    let codexDataPath: String?
    let refreshInterval: TimeInterval?
    let weekStartsMonday: Bool?

    init(
        command: DashboardLifecycleCommand,
        token: String,
        hostPID: Int32,
        helperPID: Int32,
        generation: UInt64,
        codexDataPath: String? = nil,
        refreshInterval: TimeInterval? = nil,
        weekStartsMonday: Bool? = nil
    ) {
        self.command = command
        self.token = token
        self.hostPID = hostPID
        self.helperPID = helperPID
        self.generation = generation
        self.codexDataPath = codexDataPath
        self.refreshInterval = refreshInterval
        self.weekStartsMonday = weekStartsMonday
    }
}

enum DashboardProcessRuntimeEvent: Equatable {
    case launched(pid: Int32, arguments: [String])
    case terminated(pid: Int32, arguments: [String], launchDate: Date?)
}

struct DashboardProcessIdentity: Equatable {
    let pid: Int32
    let arguments: [String]
    let launchDate: Date?

    init(pid: Int32, arguments: [String], launchDate: Date? = nil) {
        self.pid = pid
        self.arguments = arguments
        self.launchDate = launchDate
    }
}

private struct DashboardWorkspaceApplication: Sendable {
    let processIdentifier: Int32
    let bundleURL: URL?
    let launchDate: Date?
}

private func dashboardWorkspaceApplicationInfo(
    from notification: Notification
) -> DashboardWorkspaceApplication? {
    guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
        return nil
    }
    return DashboardWorkspaceApplication(
        processIdentifier: application.processIdentifier,
        bundleURL: application.bundleURL,
        launchDate: application.launchDate
    )
}

func dashboardTerminationMatchesHelper(
    processIdentifier: Int32,
    bundleURL: URL?,
    launchDate: Date?,
    helperURL: URL,
    knownHelperIdentities: [Int32: DashboardProcessIdentity]
) -> Bool {
    guard let knownIdentity = knownHelperIdentities[processIdentifier] else {
        return bundleURL?.resolvingSymlinksInPath().standardizedFileURL
            == helperURL.resolvingSymlinksInPath().standardizedFileURL
    }

    if let launchDate, let knownLaunchDate = knownIdentity.launchDate {
        return launchDate == knownLaunchDate
    }

    return true
}

@MainActor
protocol DashboardProcessRuntime: AnyObject {
    func launch(arguments: [String], completion: @escaping @MainActor (Result<DashboardProcessIdentity, Error>) -> Void)
    func activate(pid: Int32)
    func terminate(pid: Int32)
    @discardableResult
    func observe(_ handler: @escaping @MainActor (DashboardProcessRuntimeEvent) -> Void) -> AnyObject
}

@MainActor
protocol DashboardLifecycleBus: AnyObject {
    @discardableResult
    func observe(_ handler: @escaping @MainActor (DashboardLifecycleMessage) -> Void) -> AnyObject
    func post(_ message: DashboardLifecycleMessage)
}

@MainActor
protocol DashboardCoordinatorScheduler: AnyObject {
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AnyObject
}

@MainActor
protocol DashboardLifecycleNotificationCenter: AnyObject {
    func addObserver(
        _ observer: DistributedDashboardLifecycleObserver,
        selector: Selector,
        name: Notification.Name,
        object: String?,
        suspensionBehavior: DistributedNotificationCenter.SuspensionBehavior
    )
    func removeObserver(_ observer: DistributedDashboardLifecycleObserver)
    func post(name: Notification.Name, object: String?, userInfo: [AnyHashable: Any]?)
}

private final class DashboardObservationToken: NSObject {
    private let onCancel: () -> Void
    private var cancelled = false

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        onCancel()
    }

    deinit {
        cancel()
    }
}

enum DashboardLifecycleChannel {
    static let ready = Notification.Name("com.chunyangwen.CodexDashboard.DashboardUI.ready")
    static let hostToHelper = Notification.Name("com.chunyangwen.CodexDashboard.DashboardUI.host-command")
    static let helperToHost = Notification.Name("com.chunyangwen.CodexDashboard.DashboardUI.host-request")
}

private enum DashboardProcessProtocol {
    static let readyNotificationName = DashboardLifecycleChannel.ready
    static let hostToHelperNotificationName = DashboardLifecycleChannel.hostToHelper
    static let helperToHostNotificationName = DashboardLifecycleChannel.helperToHost
    static let commandKey = "command"
    static let tokenKey = "launchToken"
    static let hostPIDKey = "hostPID"
    static let helperPIDKey = "helperPID"
    static let generationKey = "generation"
    static let processIDKey = "processID"
    static let codexDataPathKey = DashboardPreferences.codexDataPathKey
    static let refreshIntervalKey = DashboardPreferences.metricsRefreshIntervalKey
    static let weekStartsMondayKey = DashboardPreferences.weekStartsMondayKey
    static let launchTokenArgument = "--codex-dashboard-launch-token"
    static let hostPIDArgument = "--codex-dashboard-host-pid"
    static let generationArgument = "--codex-dashboard-generation"
    static let codexDataPathArgument = "--codex-dashboard-data-path"
}

@MainActor
final class NSWorkspaceDashboardProcessRuntime: DashboardProcessRuntime {
    private let workspace: NSWorkspace
    private let helperURL: URL
    private var handlers: [UUID: @MainActor (DashboardProcessRuntimeEvent) -> Void] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var knownHelperIdentities: [Int32: DashboardProcessIdentity] = [:]

    init(helperURL: URL, workspace: NSWorkspace = .shared) {
        self.helperURL = helperURL
        self.workspace = workspace
        let notificationCenter = workspace.notificationCenter
        workspaceObservers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = dashboardWorkspaceApplicationInfo(from: notification) else { return }
            MainActor.assumeIsolated {
                self?.handleWorkspaceNotification(application: application, launched: true)
            }
        })
        workspaceObservers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = dashboardWorkspaceApplicationInfo(from: notification) else { return }
            MainActor.assumeIsolated {
                self?.handleWorkspaceNotification(application: application, launched: false)
            }
        })
    }

    func launch(arguments: [String], completion: @escaping @MainActor (Result<DashboardProcessIdentity, Error>) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = true
        configuration.hides = false
        workspace.openApplication(at: helperURL, configuration: configuration) { application, error in
            Task { @MainActor in
                if let error {
                    completion(.failure(error))
                } else if let application {
                    let identity = DashboardProcessIdentity(
                        pid: application.processIdentifier,
                        arguments: arguments,
                        launchDate: application.launchDate
                    )
                    self.knownHelperIdentities[application.processIdentifier] = identity
                    completion(.success(identity))
                } else {
                    completion(.failure(NSError(
                        domain: "CodexDashboard.DashboardProcessCoordinator",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "NSWorkspace did not return a helper application"]
                    )))
                }
            }
        }
    }

    func activate(pid: Int32) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    }

    func terminate(pid: Int32) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    @discardableResult
    func observe(_ handler: @escaping @MainActor (DashboardProcessRuntimeEvent) -> Void) -> AnyObject {
        let id = UUID()
        handlers[id] = handler
        return DashboardObservationToken { [weak self] in
            self?.handlers.removeValue(forKey: id)
        }
    }

    private func handleWorkspaceNotification(application: DashboardWorkspaceApplication, launched: Bool) {
        guard dashboardTerminationMatchesHelper(
            processIdentifier: application.processIdentifier,
            bundleURL: application.bundleURL,
            launchDate: application.launchDate,
            helperURL: helperURL,
            knownHelperIdentities: knownHelperIdentities
        )
        else { return }

        let knownIdentity = knownHelperIdentities[application.processIdentifier]

        let event: DashboardProcessRuntimeEvent = launched
            ? .launched(pid: application.processIdentifier, arguments: [])
            : .terminated(
                pid: application.processIdentifier,
                arguments: knownIdentity?.arguments ?? [],
                launchDate: application.launchDate
            )
        if !launched {
            knownHelperIdentities.removeValue(forKey: application.processIdentifier)
        }
        handlers.values.forEach { $0(event) }
    }

}

@MainActor
final class DistributedDashboardNotificationCenter: DashboardLifecycleNotificationCenter {
    private let center: DistributedNotificationCenter

    init(center: DistributedNotificationCenter = .default()) {
        self.center = center
    }

    func addObserver(
        _ observer: DistributedDashboardLifecycleObserver,
        selector: Selector,
        name: Notification.Name,
        object: String?,
        suspensionBehavior: DistributedNotificationCenter.SuspensionBehavior
    ) {
        center.addObserver(
            observer,
            selector: selector,
            name: name,
            object: object,
            suspensionBehavior: suspensionBehavior
        )
    }

    func removeObserver(_ observer: DistributedDashboardLifecycleObserver) {
        center.removeObserver(observer)
    }

    func post(name: Notification.Name, object: String?, userInfo: [AnyHashable: Any]?) {
        center.post(name: name, object: object, userInfo: userInfo)
    }
}

@MainActor
final class DistributedDashboardLifecycleBus: DashboardLifecycleBus {
    private let center: DashboardLifecycleNotificationCenter

    init(center: DashboardLifecycleNotificationCenter = DistributedDashboardNotificationCenter()) {
        self.center = center
    }

    @discardableResult
    func observe(_ handler: @escaping @MainActor (DashboardLifecycleMessage) -> Void) -> AnyObject {
        let observer = DistributedDashboardLifecycleObserver(
            onReady: { notification in
                guard let message = Self.message(from: notification, defaultCommand: .ready) else { return }
                DispatchQueue.main.async {
                    handler(message)
                }
            },
            onCommand: { notification in
                guard let message = Self.message(from: notification, defaultCommand: nil) else { return }
                DispatchQueue.main.async {
                    handler(message)
                }
            }
        )
        center.addObserver(
            observer,
            selector: #selector(DistributedDashboardLifecycleObserver.receiveReady(_:)),
            name: DashboardProcessProtocol.readyNotificationName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        center.addObserver(
            observer,
            selector: #selector(DistributedDashboardLifecycleObserver.receiveCommand(_:)),
            name: DashboardProcessProtocol.helperToHostNotificationName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        return DashboardObservationToken { [center, observer] in
            center.removeObserver(observer)
        }
    }

    nonisolated private static func message(
        from notification: Notification,
        defaultCommand: DashboardLifecycleCommand?
    ) -> DashboardLifecycleMessage? {
        guard
            let values = notification.userInfo,
            let token = values[DashboardProcessProtocol.tokenKey] as? String,
            let hostPID = (values[DashboardProcessProtocol.hostPIDKey] as? NSNumber)?.int32Value,
            let helperPID = (values[DashboardProcessProtocol.processIDKey] as? NSNumber)?.int32Value
                ?? (values[DashboardProcessProtocol.helperPIDKey] as? NSNumber)?.int32Value,
            let generation = (values[DashboardProcessProtocol.generationKey] as? NSNumber)?.uint64Value
        else { return nil }
        let command = (values[DashboardProcessProtocol.commandKey] as? String)
            .flatMap(DashboardLifecycleCommand.init(rawValue:)) ?? defaultCommand
        guard let command else { return nil }
        return DashboardLifecycleMessage(
            command: command,
            token: token,
            hostPID: hostPID,
            helperPID: helperPID,
            generation: generation,
            codexDataPath: values[DashboardProcessProtocol.codexDataPathKey] as? String,
            refreshInterval: (values[DashboardProcessProtocol.refreshIntervalKey] as? NSNumber)?.doubleValue,
            weekStartsMonday: (values[DashboardProcessProtocol.weekStartsMondayKey] as? NSNumber)?.boolValue
        )
    }

    func post(_ message: DashboardLifecycleMessage) {
        var userInfo: [AnyHashable: Any] = [
            DashboardProcessProtocol.commandKey: message.command.rawValue,
            DashboardProcessProtocol.tokenKey: message.token,
            DashboardProcessProtocol.hostPIDKey: NSNumber(value: message.hostPID),
            DashboardProcessProtocol.processIDKey: NSNumber(value: message.helperPID),
            DashboardProcessProtocol.generationKey: NSNumber(value: message.generation)
        ]
        if let codexDataPath = message.codexDataPath {
            userInfo[DashboardProcessProtocol.codexDataPathKey] = codexDataPath
        }
        if let refreshInterval = message.refreshInterval {
            userInfo[DashboardProcessProtocol.refreshIntervalKey] = NSNumber(value: refreshInterval)
        }
        if let weekStartsMonday = message.weekStartsMonday {
            userInfo[DashboardProcessProtocol.weekStartsMondayKey] = NSNumber(value: weekStartsMonday)
        }
        center.post(
            name: DashboardProcessProtocol.hostToHelperNotificationName,
            object: nil,
            userInfo: userInfo
        )
    }
}

final class DistributedDashboardLifecycleObserver: NSObject {
    private let onReady: (Notification) -> Void
    private let onCommand: (Notification) -> Void

    init(
        onReady: @escaping (Notification) -> Void,
        onCommand: @escaping (Notification) -> Void
    ) {
        self.onReady = onReady
        self.onCommand = onCommand
    }

    @objc func receiveReady(_ notification: Notification) {
        onReady(notification)
    }

    @objc func receiveCommand(_ notification: Notification) {
        onCommand(notification)
    }
}

@MainActor
final class DispatchDashboardCoordinatorScheduler: DashboardCoordinatorScheduler {
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AnyObject {
        let box = DashboardScheduledActionBox(action: action)
        let task = Task { [box] in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            } catch {
                return
            }
            await MainActor.run { box.action() }
        }
        return DashboardObservationToken {
            task.cancel()
        }
    }
}

private final class DashboardScheduledActionBox: @unchecked Sendable {
    let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }
}

@MainActor
final class DashboardProcessCoordinator {
    nonisolated static let defaultLaunchTimeout: TimeInterval = 5
    nonisolated static let defaultTerminationTimeout: TimeInterval = 2

    private let helperURL: URL
    private let hostPID: Int32
    private let runtime: DashboardProcessRuntime
    private let lifecycleBus: DashboardLifecycleBus
    private let scheduler: DashboardCoordinatorScheduler
    private let launchTimeout: TimeInterval
    private let terminationTimeout: TimeInterval
    private let preferences: UserDefaults
    private let codexDataPathProvider: @MainActor () -> String?
    private var runtimeObservation: AnyObject?
    private var lifecycleObservation: AnyObject?
    private var timeoutObservation: AnyObject?
    private var helperLivenessTimer: Timer?
    private var abandonedLaunchTokens: Set<String> = []
    private var terminationWaiters: [@MainActor () -> Void] = []
    private(set) var state: DashboardProcessState = .stopped
    private(set) var currentHelperPID: Int32?
    private(set) var currentHelperLaunchDate: Date?
    private(set) var currentLaunchToken: String?
    private(set) var currentGeneration: UInt64 = 0
    var stateDidChange: (@MainActor (DashboardProcessState) -> Void)?

    init(
        helperURL: URL,
        hostPID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        runtime: DashboardProcessRuntime? = nil,
        lifecycleBus: DashboardLifecycleBus? = nil,
        scheduler: DashboardCoordinatorScheduler? = nil,
        launchTimeout: TimeInterval = DashboardProcessCoordinator.defaultLaunchTimeout,
        terminationTimeout: TimeInterval = DashboardProcessCoordinator.defaultTerminationTimeout,
        preferences: UserDefaults = DashboardPreferences.sharedDefaults(),
        codexDataPathProvider: @escaping @MainActor () -> String? = {
            DashboardPreferences.sharedDefaults().string(forKey: DashboardPreferences.codexDataPathKey)
        }
    ) {
        self.helperURL = helperURL
        self.hostPID = hostPID
        self.runtime = runtime ?? NSWorkspaceDashboardProcessRuntime(helperURL: helperURL)
        self.lifecycleBus = lifecycleBus ?? DistributedDashboardLifecycleBus()
        self.scheduler = scheduler ?? DispatchDashboardCoordinatorScheduler()
        self.launchTimeout = launchTimeout
        self.terminationTimeout = terminationTimeout
        self.preferences = preferences
        self.codexDataPathProvider = codexDataPathProvider
        runtimeObservation = self.runtime.observe { [weak self] event in
            self?.handle(event)
        }
        lifecycleObservation = self.lifecycleBus.observe { [weak self] message in
            self?.handle(message)
        }
    }

    func requestDashboard() {
        switch state {
        case .stopped:
            beginLaunch()
        case .launching:
            break
        case .ready:
            focusHelper()
        case .terminating:
            break
        }
    }

    func openSettings() {
        send(.openSettings)
    }

    func checkForUpdates() {
        send(.checkForUpdates)
    }

    func refreshMetrics() {
        send(.refreshMetrics)
    }

    func rebuildHistoryIndex() {
        send(.rebuildHistoryIndex)
    }

    func settingsChanged() {
        guard state == .ready else { return }
        send(
            .settingsChanged,
            codexDataPath: preferences.string(forKey: DashboardPreferences.codexDataPathKey),
            refreshInterval: preferences.object(forKey: DashboardPreferences.metricsRefreshIntervalKey) as? Double,
            weekStartsMonday: preferences.object(forKey: DashboardPreferences.weekStartsMondayKey) as? Bool
        )
    }

    func acceptsHelperCommand(_ message: DashboardLifecycleMessage) -> Bool {
        state == .ready
            && message.command != .ready
            && message.hostPID == hostPID
            && message.helperPID == currentHelperPID
            && message.token == currentLaunchToken
            && message.generation == currentGeneration
    }

    func terminateForHostQuit(completion: (@MainActor () -> Void)? = nil) {
        if state == .stopped {
            completion?()
            return
        }
        if let completion { terminationWaiters.append(completion) }
        if state == .launching, let token = currentLaunchToken {
            abandonedLaunchTokens.insert(token)
        }
        updateState(.terminating)
        timeoutObservation = scheduler.schedule(after: terminationTimeout) { [weak self] in
            self?.finishStopped()
        }
        guard let helperPID = currentHelperPID else {
            finishStopped()
            return
        }
        lifecycleBus.post(DashboardLifecycleMessage(
            command: .quitProduct,
            token: currentLaunchToken ?? "",
            hostPID: hostPID,
            helperPID: helperPID,
            generation: currentGeneration
        ))
        runtime.terminate(pid: helperPID)
    }

    private func beginLaunch() {
        currentGeneration &+= 1
        let token = UUID().uuidString
        currentLaunchToken = token
        currentHelperPID = nil
        currentHelperLaunchDate = nil
        updateState(.launching)

        let arguments = [
            DashboardProcessProtocol.launchTokenArgument, token,
            DashboardProcessProtocol.hostPIDArgument, String(hostPID),
            DashboardProcessProtocol.generationArgument, String(currentGeneration)
        ] + (codexDataPathProvider().map {
            [DashboardProcessProtocol.codexDataPathArgument, $0]
        } ?? [])
        let generation = currentGeneration
        timeoutObservation = scheduler.schedule(after: launchTimeout) { [weak self] in
            self?.handleLaunchTimeout(token: token, generation: generation)
        }
        runtime.launch(arguments: arguments) { [weak self] result in
            self?.handleLaunchResult(result, token: token, generation: generation)
        }
    }

    private func handleLaunchResult(
        _ result: Result<DashboardProcessIdentity, Error>,
        token: String,
        generation: UInt64
    ) {
        guard state == .launching, currentLaunchToken == token, currentGeneration == generation else {
            if abandonedLaunchTokens.remove(token) != nil,
               case .success(let identity) = result,
               currentHelperPID != identity.pid {
                runtime.terminate(pid: identity.pid)
            }
            return
        }
        switch result {
        case .success(let identity):
            currentHelperPID = identity.pid
            currentHelperLaunchDate = identity.launchDate
        case .failure:
            finishStopped()
        }
    }

    private func handle(_ event: DashboardProcessRuntimeEvent) {
        switch event {
        case .launched:
            // NSWorkspace launch notifications do not carry the launch
            // arguments. The openApplication completion and ready handshake
            // are the only sources allowed to establish the helper PID.
            break
        case .terminated(let pid, let arguments, let launchDate):
            guard currentHelperPID == pid else { return }
            if let launchDate,
               let currentHelperLaunchDate,
               launchDate != currentHelperLaunchDate {
                return
            }
            if let token = arguments.value(for: DashboardProcessProtocol.launchTokenArgument), token != currentLaunchToken { return }
            finishStopped()
        }
    }

    private func handle(_ message: DashboardLifecycleMessage) {
        guard message.hostPID == hostPID else { return }
        guard message.token == currentLaunchToken else { return }
        guard message.generation == currentGeneration else { return }
        guard message.helperPID > 0 else { return }

        if message.command == .helperClosing {
            guard state == .ready, currentHelperPID == message.helperPID else { return }
            finishStopped()
            return
        }

        guard state == .launching, message.command == .ready else { return }
        if let currentHelperPID, currentHelperPID != message.helperPID { return }

        currentHelperPID = message.helperPID
        updateState(.ready)
        timeoutObservation = nil
        startHelperLivenessMonitor()
        focusHelper()
    }

    private func focusHelper() {
        guard state == .ready, let helperPID = currentHelperPID else { return }
        runtime.activate(pid: helperPID)
        send(.focus)
    }

    private func send(
        _ command: DashboardLifecycleCommand,
        codexDataPath: String? = nil,
        refreshInterval: TimeInterval? = nil,
        weekStartsMonday: Bool? = nil
    ) {
        guard let helperPID = currentHelperPID, let token = currentLaunchToken else { return }
        lifecycleBus.post(DashboardLifecycleMessage(
            command: command,
            token: token,
            hostPID: hostPID,
            helperPID: helperPID,
            generation: currentGeneration,
            codexDataPath: codexDataPath,
            refreshInterval: refreshInterval,
            weekStartsMonday: weekStartsMonday
        ))
    }

    private func handleLaunchTimeout(token: String, generation: UInt64) {
        guard state == .launching, currentLaunchToken == token, currentGeneration == generation else { return }
        abandonedLaunchTokens.insert(token)
        let helperPID = currentHelperPID
        finishStopped()
        if let helperPID {
            runtime.terminate(pid: helperPID)
        }
    }

    private func finishStopped() {
        timeoutObservation = nil
        helperLivenessTimer?.invalidate()
        helperLivenessTimer = nil
        updateState(.stopped)
        currentHelperPID = nil
        currentHelperLaunchDate = nil
        currentLaunchToken = nil
        let waiters = terminationWaiters
        terminationWaiters.removeAll()
        waiters.forEach { $0() }
    }

    private func updateState(_ newState: DashboardProcessState) {
        guard state != newState else { return }
        state = newState
        stateDidChange?(newState)
    }

    private func startHelperLivenessMonitor() {
        helperLivenessTimer?.invalidate()
        helperLivenessTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.state == .ready,
                      let helperPID = self.currentHelperPID,
                      let helper = NSRunningApplication(processIdentifier: helperPID),
                      !helper.isTerminated else {
                    self?.finishStopped()
                    return
                }
            }
        }
    }
}

private extension Array where Element == String {
    func value(for flag: String) -> String? {
        guard let index = firstIndex(of: flag), index + 1 < count else { return nil }
        return self[index + 1]
    }
}

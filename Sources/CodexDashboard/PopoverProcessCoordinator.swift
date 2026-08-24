import AppKit

enum PopoverProcessState: Equatable {
    case stopped
    case launching
    case ready
    case terminating
}

private struct PopoverHostMessage: Sendable {
    let token: String?
    let hostPID: Int32?
    let generation: UInt64?
    let processID: Int32?
    let command: String?
}

@MainActor
final class PopoverProcessCoordinator {
    private let workspace: NSWorkspace
    private let popoverURL: URL
    private let hostPID: Int32
    private let center: DistributedNotificationCenter
    private var notificationObserver: NSObjectProtocol?
    private var workspaceObserver: NSObjectProtocol?
    private var terminationTimer: Timer?
    private(set) var state: PopoverProcessState = .stopped
    private(set) var currentPID: Int32?
    private(set) var currentToken: String?
    private(set) var currentGeneration: UInt64 = 0
    private var terminationCompletions: [() -> Void] = []

    var commandHandler: ((PopoverLifecycleCommand) -> Void)?

    init(
        popoverURL: URL,
        hostPID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        workspace: NSWorkspace = .shared,
        center: DistributedNotificationCenter = .default()
    ) {
        self.popoverURL = popoverURL
        self.hostPID = hostPID
        self.workspace = workspace
        self.center = center
        notificationObserver = center.addObserver(
            forName: PopoverProcessProtocol.popoverToHostNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let values = notification.userInfo
            let message = PopoverHostMessage(
                token: values?[PopoverProcessProtocol.tokenKey] as? String,
                hostPID: (values?[PopoverProcessProtocol.hostPIDKey] as? NSNumber)?.int32Value,
                generation: (values?[PopoverProcessProtocol.generationKey] as? NSNumber)?.uint64Value,
                processID: (values?[PopoverProcessProtocol.processIDKey] as? NSNumber)?.int32Value,
                command: values?[PopoverProcessProtocol.commandKey] as? String
            )
            MainActor.assumeIsolated {
                self?.handle(message)
            }
        }
        workspaceObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                guard let self, application.processIdentifier == self.currentPID else { return }
                self.helperDidTerminate()
            }
        }
    }

    func requestPopover(anchor: NSRect) {
        switch state {
        case .stopped:
            beginLaunch(anchor: anchor)
        case .launching, .ready:
            send(.focus)
        case .terminating:
            break
        }
    }

    func terminate(completion: (() -> Void)? = nil) {
        if let completion { terminationCompletions.append(completion) }
        guard state != .stopped else {
            finishStopped()
            return
        }
        guard state != .terminating else { return }
        state = .terminating
        terminationTimer?.invalidate()
        terminationTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finishStopped()
            }
        }
        send(.closing)
        if let currentPID {
            NSRunningApplication(processIdentifier: currentPID)?.terminate()
        } else {
            finishStopped()
        }
    }

    private func beginLaunch(anchor: NSRect) {
        currentGeneration &+= 1
        let token = UUID().uuidString
        currentToken = token
        currentPID = nil
        state = .launching
        var arguments: [String] = []
        arguments += [PopoverProcessProtocol.launchTokenArgument, token]
        arguments += [PopoverProcessProtocol.hostPIDArgument, String(hostPID)]
        arguments += [PopoverProcessProtocol.generationArgument, String(currentGeneration)]
        arguments += [PopoverProcessProtocol.anchorXArgument, String(Double(anchor.minX))]
        arguments += [PopoverProcessProtocol.anchorYArgument, String(Double(anchor.minY))]
        arguments += [PopoverProcessProtocol.anchorWidthArgument, String(Double(anchor.width))]
        arguments += [PopoverProcessProtocol.anchorHeightArgument, String(Double(anchor.height))]
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = false
        configuration.hides = true
        workspace.openApplication(at: popoverURL, configuration: configuration) { [weak self] application, error in
            Task { @MainActor [weak self] in
                guard let self, self.state == .launching, self.currentToken == token else { return }
                guard error == nil, let application else {
                    self.finishStopped()
                    return
                }
                self.currentPID = application.processIdentifier
            }
        }
        terminationTimer?.invalidate()
        terminationTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .launching else { return }
                self.terminate()
            }
        }
    }

    private func handle(_ message: PopoverHostMessage) {
        guard
            let token = message.token,
            token == currentToken,
            let hostPID = message.hostPID,
            hostPID == self.hostPID,
            let generation = message.generation,
            generation == currentGeneration,
            let commandRaw = message.command,
            let command = PopoverLifecycleCommand(rawValue: commandRaw)
        else { return }

        let messagePID = message.processID
        guard let messagePID, messagePID > 0 else { return }
        if let currentPID, currentPID != messagePID { return }
        currentPID = messagePID

        switch command {
        case .ready:
            guard state == .launching else { return }
            terminationTimer?.invalidate()
            terminationTimer = nil
            state = .ready
            // Acknowledge the helper's retryable ready handshake.
            send(.focus)
        case .closing:
            finishStopped()
        case .openDashboard, .openSettings, .quitProduct:
            commandHandler?(command)
        case .focus:
            send(.focus)
        }
    }

    private func send(_ command: PopoverLifecycleCommand) {
        guard let currentPID, let currentToken else { return }
        center.post(
            name: PopoverProcessProtocol.hostToPopoverNotification,
            object: nil,
            userInfo: [
                PopoverProcessProtocol.commandKey: command.rawValue,
                PopoverProcessProtocol.tokenKey: currentToken,
                PopoverProcessProtocol.hostPIDKey: NSNumber(value: hostPID),
                PopoverProcessProtocol.processIDKey: NSNumber(value: currentPID),
                PopoverProcessProtocol.generationKey: NSNumber(value: currentGeneration)
            ]
        )
    }

    func helperDidTerminate() {
        finishStopped()
    }

    private func finishStopped() {
        terminationTimer?.invalidate()
        terminationTimer = nil
        state = .stopped
        currentPID = nil
        currentToken = nil
        let completions = terminationCompletions
        terminationCompletions.removeAll()
        completions.forEach { $0() }
    }
}

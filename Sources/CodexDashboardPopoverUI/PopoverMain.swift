import AppKit
import SwiftUI

@MainActor
private final class PopoverAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private struct HostCommand: Sendable {
        let token: String?
        let hostPID: Int32?
        let processID: Int32?
        let generation: UInt64?
        let command: String?
    }

    private let center = DistributedNotificationCenter.default()
    private var store: MenuBarStore!
    private var panel: NSPanel?
    private var hostWatchdog: Timer?
    private var readyTimer: Timer?
    private var outsideClickMonitor: Any?
    private var notificationObserver: NSObjectProtocol?
    private var launchToken: String?
    private var hostPID: Int32?
    private var generation: UInt64 = 0
    private var anchor = NSRect.zero
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard readLaunchArguments() else {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        store = MenuBarStore(defaults: DashboardPreferences.sharedDefaults())
        observeHostCommands()
        startHostWatchdog()
        showPanel()
        store.loadPopover()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let notificationObserver {
            center.removeObserver(notificationObserver)
        }
        hostWatchdog?.invalidate()
        hostWatchdog = nil
        readyTimer?.invalidate()
        readyTimer = nil
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        store?.releasePopover()
    }

    private func readLaunchArguments() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard
            let tokenIndex = arguments.firstIndex(of: PopoverProcessProtocol.launchTokenArgument),
            arguments.indices.contains(arguments.index(after: tokenIndex)),
            let hostIndex = arguments.firstIndex(of: PopoverProcessProtocol.hostPIDArgument),
            arguments.indices.contains(arguments.index(after: hostIndex)),
            let parsedHostPID = Int32(arguments[arguments.index(after: hostIndex)]),
            let generationIndex = arguments.firstIndex(of: PopoverProcessProtocol.generationArgument),
            arguments.indices.contains(arguments.index(after: generationIndex)),
            let parsedGeneration = UInt64(arguments[arguments.index(after: generationIndex)])
        else { return false }

        launchToken = arguments[arguments.index(after: tokenIndex)]
        hostPID = parsedHostPID
        generation = parsedGeneration
        anchor = NSRect(
            x: argumentValue(arguments, key: PopoverProcessProtocol.anchorXArgument),
            y: argumentValue(arguments, key: PopoverProcessProtocol.anchorYArgument),
            width: argumentValue(arguments, key: PopoverProcessProtocol.anchorWidthArgument),
            height: argumentValue(arguments, key: PopoverProcessProtocol.anchorHeightArgument)
        )
        return launchToken != nil && hostPID != nil
    }

    private func argumentValue(_ arguments: [String], key: String) -> CGFloat {
        guard let index = arguments.firstIndex(of: key), arguments.indices.contains(arguments.index(after: index)) else {
            return 0
        }
        return CGFloat(Double(arguments[arguments.index(after: index)]) ?? 0)
    }

    private func observeHostCommands() {
        notificationObserver = center.addObserver(
            forName: PopoverProcessProtocol.hostToPopoverNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let values = notification.userInfo
            let command = HostCommand(
                token: values?[PopoverProcessProtocol.tokenKey] as? String,
                hostPID: (values?[PopoverProcessProtocol.hostPIDKey] as? NSNumber)?.int32Value,
                processID: (values?[PopoverProcessProtocol.processIDKey] as? NSNumber)?.int32Value,
                generation: (values?[PopoverProcessProtocol.generationKey] as? NSNumber)?.uint64Value,
                command: values?[PopoverProcessProtocol.commandKey] as? String
            )
            MainActor.assumeIsolated {
                self?.handleHostCommand(command)
            }
        }
    }

    private func handleHostCommand(_ command: HostCommand) {
        guard isAuthenticated(command),
              let rawValue = command.command,
              let command = PopoverLifecycleCommand(rawValue: rawValue)
        else { return }

        switch command {
        case .focus:
            readyTimer?.invalidate()
            readyTimer = nil
            panel?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        case .closing:
            isTerminating = true
            NSApp.terminate(nil)
        case .ready, .openDashboard, .openSettings, .quitProduct:
            break
        }
    }

    private func isAuthenticated(_ command: HostCommand) -> Bool {
        guard command.token == launchToken,
              command.hostPID == hostPID,
              command.processID == Int32(ProcessInfo.processInfo.processIdentifier),
              command.generation == generation
        else { return false }
        return true
    }

    private func showPanel() {
        let root = MenuBarDashboardView { [weak self] command in
            self?.send(command)
        }
        .environmentObject(store)
        let hostingController = NSHostingController(rootView: root)
        let panel = NSPanel(contentViewController: hostingController)
        panel.styleMask = NSWindow.StyleMask.borderless
        panel.isOpaque = false
        panel.backgroundColor = NSColor.clear
        panel.hasShadow = true
        panel.level = NSWindow.Level.popUpMenu
        panel.collectionBehavior = [.ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = true
        panel.delegate = self

        let width: CGFloat = 390
        let height: CGFloat = 620
        panel.setContentSize(NSSize(width: width, height: height))
        panel.setFrameOrigin(panelOrigin(size: NSSize(width: width, height: height)))
        self.panel = panel
        // Finish all layout and data wiring before ordering the panel in front;
        // this avoids a visible blank frame on first presentation.
        hostingController.view.layoutSubtreeIfNeeded()
        panel.makeKeyAndOrderFront(nil as Any?)
        NSApp.activate(ignoringOtherApps: true)
        beginReadyHandshake()

        // The status-item mouse-up launches this helper. Install dismissal on
        // the next run-loop turn so that opening gesture can never close it.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isTerminating, self.outsideClickMonitor == nil else { return }
            self.outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let panel = self.panel, panel.isVisible,
                          !panel.frame.contains(NSEvent.mouseLocation) else { return }
                    self.send(.closing)
                }
            }
        }
    }

    /// Distributed notifications sent during the first app-launch turn can
    /// precede the host's NSWorkspace completion. Retry until the host echoes
    /// `.focus` as an acknowledgement, preventing its launch timeout from
    /// terminating an already-visible popup.
    private func beginReadyHandshake() {
        readyTimer?.invalidate()
        readyTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isTerminating else { return }
                self.send(.ready)
            }
        }
        send(.ready)
    }

    private func panelOrigin(size: NSSize) -> NSPoint {
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: size.width + 16, height: size.height + 16)
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let y = max(visible.minY + 8, anchor.minY - size.height)
        return NSPoint(x: x, y: y)
    }

    private func send(_ command: PopoverLifecycleCommand) {
        guard let launchToken, let hostPID else { return }
        let processID = NSNumber(value: Int32(ProcessInfo.processInfo.processIdentifier))
        center.post(
            name: PopoverProcessProtocol.popoverToHostNotification,
            object: nil,
            userInfo: [
                PopoverProcessProtocol.commandKey: command.rawValue,
                PopoverProcessProtocol.tokenKey: launchToken,
                PopoverProcessProtocol.hostPIDKey: NSNumber(value: hostPID),
                PopoverProcessProtocol.popoverPIDKey: processID,
                PopoverProcessProtocol.processIDKey: processID,
                PopoverProcessProtocol.generationKey: NSNumber(value: generation)
            ]
        )
        guard command != .ready, command != .focus else { return }
        isTerminating = true
        NSApp.terminate(nil)
    }

    private func send(_ command: MenuBarPopoverCommand) {
        switch command {
        case .openDashboard: send(PopoverLifecycleCommand.openDashboard)
        case .openSettings: send(PopoverLifecycleCommand.openSettings)
        case .quitProduct: send(PopoverLifecycleCommand.quitProduct)
        }
    }

    private func startHostWatchdog() {
        hostWatchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let hostPID = self.hostPID else { return }
                if NSRunningApplication(processIdentifier: hostPID) == nil {
                    self.isTerminating = true
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

@main
private struct CodexDashboardPopoverApplication: App {
    @NSApplicationDelegateAdaptor(PopoverAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

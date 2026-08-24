import AppKit
import SwiftUI

private enum HelperLifecycleNotification {
    static let ready = Notification.Name("com.chunyangwen.CodexDashboard.DashboardUI.ready")
    static let hostToHelper = Notification.Name("com.chunyangwen.CodexDashboard.DashboardUI.host-command")
    static let helperToHost = Notification.Name("com.chunyangwen.CodexDashboard.DashboardUI.host-request")
    static let launchTokenArgument = "--codex-dashboard-launch-token"
    static let hostPIDArgument = "--codex-dashboard-host-pid"
    static let generationArgument = "--codex-dashboard-generation"
    static let tokenKey = "launchToken"
    static let hostPIDKey = "hostPID"
    static let helperPIDKey = "helperPID"
    static let commandKey = "command"
    static let processIDKey = "processID"
    static let generationKey = "generation"
}

private enum HelperHostCommand: String {
    case helperClosing
    case openSettings
    case checkForUpdates
    case quitProduct
}

@MainActor
private final class HelperAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let lifecycleCenter = DistributedNotificationCenter.default()
    private var dashboardStore: DashboardStore!
    private var dashboardWindow: NSWindow?
    private var conversationWindows: [ConversationWindowRequest: NSWindow] = [:]
    private var hostFallbackWatchdog: Timer?
    private var hostTerminationObserver: NSObjectProtocol?
    private var launchToken: String?
    private var hostProcessIdentifier: pid_t?
    private var launchGeneration: UInt64 = 0
    private var launchCodexHome: URL?
    private var sentReady = false
    private var observesLifecycleCommands = false
    private var isTerminatingForHost = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        readLaunchArguments()
        dashboardStore = DashboardStore(
            defaults: DashboardPreferences.sharedDefaults(),
            codexHome: launchCodexHome
        )
        observeLifecycleCommands()
        startHostWatchdog()
        installMainMenu()
        createDashboardWindow()
        showDashboardWindow()
        dashboardStore.load()
        DispatchQueue.main.async { [weak self] in
            self?.sendReadyIfWindowIsVisible(self?.dashboardWindow)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminatingForHost { return .terminateNow }
        postCommandToHost(.quitProduct)
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        lifecycleCenter.removeObserver(self, name: HelperLifecycleNotification.hostToHelper, object: nil)
        observesLifecycleCommands = false
        if let hostTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(hostTerminationObserver)
            self.hostTerminationObserver = nil
        }
        hostFallbackWatchdog?.invalidate()
        hostFallbackWatchdog = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === dashboardWindow {
            dashboardWindow = nil
        } else if let window = notification.object as? NSWindow,
                  let request = conversationWindows.first(where: { $0.value === window })?.key {
            conversationWindows.removeValue(forKey: request)
        }
        terminateIfNoOwnedWindows()
    }

    private func openConversation(_ request: ConversationWindowRequest) {
        if let existing = conversationWindows[request], existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: ConversationDebuggerWindow(request: request))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Conversation Debugger"
        window.identifier = NSUserInterfaceItemIdentifier("CodexDashboard.conversation")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 980, height: 760))
        window.center()
        window.delegate = self
        conversationWindows[request] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createDashboardWindow() {
        guard dashboardWindow == nil else { return }
        let root = DashboardHelperRoot(
            store: dashboardStore,
            openConversation: { [weak self] request in
                self?.openConversation(request)
            }
        )
        let hostingController = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Codex Dashboard"
        window.identifier = NSUserInterfaceItemIdentifier("CodexDashboard.dashboard")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.center()
        window.delegate = self
        dashboardWindow = window
    }

    private func showDashboardWindow() {
        createDashboardWindow()
        guard let dashboardWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        if dashboardWindow.isMiniaturized { dashboardWindow.deminiaturize(nil) }
        dashboardWindow.makeKeyAndOrderFront(nil)
        dashboardWindow.orderFrontRegardless()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Codex Dashboard")
        let refresh = appMenu.addItem(withTitle: "Refresh Metrics", action: #selector(refreshMetrics), keyEquivalent: "r")
        refresh.keyEquivalentModifierMask = [.command]
        refresh.target = self
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(requestSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        let updates = appMenu.addItem(withTitle: "Check for Updates…", action: #selector(requestUpdates), keyEquivalent: "")
        updates.target = self
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(withTitle: "Quit Codex Dashboard", action: #selector(requestProductQuit), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func refreshMetrics() {
        dashboardStore.load()
    }

    @objc private func requestSettings() {
        postCommandToHost(.openSettings)
    }

    @objc private func requestUpdates() {
        postCommandToHost(.checkForUpdates)
    }

    @objc private func requestProductQuit() {
        postCommandToHost(.quitProduct)
    }

    private func terminateIfNoOwnedWindows() {
        guard dashboardWindow == nil, conversationWindows.values.allSatisfy({ !$0.isVisible }) else { return }
        isTerminatingForHost = true
        postCommandToHost(.helperClosing)
        NSApp.terminate(nil)
    }

    private func readLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        guard
            let tokenIndex = arguments.firstIndex(of: HelperLifecycleNotification.launchTokenArgument),
            arguments.indices.contains(arguments.index(after: tokenIndex)),
            let hostPIDIndex = arguments.firstIndex(of: HelperLifecycleNotification.hostPIDArgument),
            arguments.indices.contains(arguments.index(after: hostPIDIndex)),
            let hostPID = Int32(arguments[arguments.index(after: hostPIDIndex)])
        else { return }

        launchToken = arguments[arguments.index(after: tokenIndex)]
        hostProcessIdentifier = pid_t(hostPID)
        if let generationIndex = arguments.firstIndex(of: HelperLifecycleNotification.generationArgument),
           arguments.indices.contains(arguments.index(after: generationIndex)) {
            launchGeneration = UInt64(arguments[arguments.index(after: generationIndex)]) ?? 0
        }
        if let pathIndex = arguments.firstIndex(of: "--codex-dashboard-data-path"),
           arguments.indices.contains(arguments.index(after: pathIndex)) {
            let path = arguments[arguments.index(after: pathIndex)]
            if !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                launchCodexHome = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            }
        }
    }

    private func observeLifecycleCommands() {
        lifecycleCenter.addObserver(
            self,
            selector: #selector(handleLifecycleNotification(_:)),
            name: HelperLifecycleNotification.hostToHelper,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        observesLifecycleCommands = true
    }

    @objc private func handleLifecycleNotification(_ notification: Notification) {
        guard
            let values = notification.userInfo,
            let launchToken = values[HelperLifecycleNotification.tokenKey] as? String,
            launchToken == self.launchToken,
            let hostPID = (values[HelperLifecycleNotification.hostPIDKey] as? NSNumber)?.int32Value,
            hostPID == self.hostProcessIdentifier,
            let targetPID = (values[HelperLifecycleNotification.processIDKey] as? NSNumber)?.int32Value,
            targetPID == ProcessInfo.processInfo.processIdentifier,
            let generation = (values[HelperLifecycleNotification.generationKey] as? NSNumber)?.uint64Value,
            generation == launchGeneration,
            let command = values[HelperLifecycleNotification.commandKey] as? String
        else { return }

        switch command {
        case "focus": focusDashboardWindow()
        case "refreshMetrics": dashboardStore.load()
        case "rebuildHistoryIndex": dashboardStore.rebuildHistoryIndex()
        case "settingsChanged":
            guard let settings = DashboardSettingsUpdate(
                userInfo: values,
                expectedToken: launchToken,
                expectedHostPID: self.hostProcessIdentifier,
                expectedHelperPID: ProcessInfo.processInfo.processIdentifier,
                expectedGeneration: launchGeneration
            ) else { return }
            dashboardStore.applySettings(
                codexDataPath: settings.codexDataPath,
                refreshInterval: settings.refreshInterval,
                weekStartsMonday: settings.weekStartsMonday
            )
        case "quitProduct":
            isTerminatingForHost = true
            NSApp.terminate(nil)
        default: break
        }
    }

    private func postCommandToHost(_ command: HelperHostCommand) {
        guard let launchToken, let hostProcessIdentifier else { return }
        lifecycleCenter.post(
            name: HelperLifecycleNotification.helperToHost,
            object: nil,
            userInfo: [
                HelperLifecycleNotification.commandKey: command.rawValue,
                HelperLifecycleNotification.tokenKey: launchToken,
                HelperLifecycleNotification.hostPIDKey: NSNumber(value: hostProcessIdentifier),
                HelperLifecycleNotification.processIDKey: NSNumber(value: ProcessInfo.processInfo.processIdentifier),
                HelperLifecycleNotification.generationKey: NSNumber(value: launchGeneration)
            ]
        )
    }

    private func focusDashboardWindow() {
        showDashboardWindow()
    }

    private func sendReadyIfWindowIsVisible(_ window: NSWindow?) {
        guard !sentReady,
              let window,
              window === dashboardWindow,
              window.isVisible,
              !window.isMiniaturized,
              let launchToken,
              let hostProcessIdentifier else { return }

        sentReady = true
        lifecycleCenter.post(
            name: HelperLifecycleNotification.ready,
            object: nil,
            userInfo: [
                HelperLifecycleNotification.tokenKey: launchToken,
                HelperLifecycleNotification.hostPIDKey: NSNumber(value: hostProcessIdentifier),
                HelperLifecycleNotification.helperPIDKey: NSNumber(value: ProcessInfo.processInfo.processIdentifier),
                HelperLifecycleNotification.generationKey: NSNumber(value: launchGeneration)
            ]
        )
    }

    private func startHostWatchdog() {
        guard hostProcessIdentifier != nil else { return }
        let notificationCenter = NSWorkspace.shared.notificationCenter
        hostTerminationObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let terminatedPID = application.processIdentifier
            Task { @MainActor [weak self] in
                guard let self, self.hostProcessIdentifier == terminatedPID else { return }
                self.terminateAfterHostDisappearance()
            }
        }
        hostFallbackWatchdog = Timer.scheduledTimer(
            withTimeInterval: 5,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let hostProcessIdentifier = self.hostProcessIdentifier,
                      let host = NSRunningApplication(processIdentifier: hostProcessIdentifier),
                      !host.isTerminated else {
                    self?.terminateAfterHostDisappearance()
                    return
                }
            }
        }
    }

    private func terminateAfterHostDisappearance() {
        guard !isTerminatingForHost else { return }
        isTerminatingForHost = true
        hostFallbackWatchdog?.invalidate()
        hostFallbackWatchdog = nil
        if let hostTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(hostTerminationObserver)
            self.hostTerminationObserver = nil
        }
        NSApp.terminate(nil)
    }
}

@main
struct HelperMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = HelperAppDelegate()
        application.delegate = delegate
        application.run()
    }
}

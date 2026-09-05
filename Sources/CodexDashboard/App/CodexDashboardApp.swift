import AppKit
import CodexMetricsCore
import ServiceManagement
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    private var startHandler: (@MainActor () -> Void)?

    private init() {}

    func configure(startHandler: @escaping @MainActor () -> Void) {
        self.startHandler = startHandler
    }

    func checkForUpdates() {
        // The dashboard helper owns the visible Dock icon while it is open.
        // Sparkle can present from the accessory host without promoting it.
        startHandler?()
    }
}

@MainActor
final class DashboardProductTerminationGate {
    enum State: Equatable {
        case idle
        case waitingForHelper
        case terminating
    }

    private(set) var state: State = .idle

    func requestFromHelper(
        helperState: DashboardProcessState,
        terminateHelper: @escaping (@escaping @MainActor () -> Void) -> Void,
        terminateHost: @escaping @MainActor () -> Void
    ) {
        guard state == .idle else { return }
        guard helperState != .stopped else {
            state = .terminating
            terminateHost()
            return
        }

        state = .waitingForHelper
        terminateHelper { [weak self] in
            guard let self, self.state == .waitingForHelper else { return }
            self.state = .terminating
            DispatchQueue.main.async {
                terminateHost()
            }
        }
    }

    func applicationShouldTerminate(
        helperState: DashboardProcessState,
        terminateHelper: @escaping (@escaping @MainActor () -> Void) -> Void,
        reply: @escaping @MainActor () -> Void
    ) -> NSApplication.TerminateReply {
        switch state {
        case .terminating:
            return .terminateNow
        case .waitingForHelper:
            return .terminateCancel
        case .idle:
            guard helperState != .stopped else {
                state = .terminating
                return .terminateNow
            }

            state = .waitingForHelper
            terminateHelper { [weak self] in
                guard let self, self.state == .waitingForHelper else { return }
                self.state = .terminating
                DispatchQueue.main.async {
                    reply()
                }
            }
            return .terminateLater
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static weak var shared: AppDelegate?

    let dashboardCoordinator: DashboardProcessCoordinator
    let menuStore: MenuBarStore
    private var statusItemController: StatusItemController?
    private var updaterController: SPUStandardUpdaterController!
    private var updateCheckInProgress = false
    private let productTerminationGate = DashboardProductTerminationGate()

    override init() {
        let defaults = DashboardPreferences.migrateLegacyDefaults()
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/CodexDashboardUI.app", isDirectory: true)
        dashboardCoordinator = DashboardProcessCoordinator(helperURL: helperURL)
        menuStore = MenuBarStore(defaults: defaults)
        super.init()
        Self.shared = self
        dashboardCoordinator.helperCommandHandler = { [weak self] command in
            self?.handleHelperCommand(command)
        }
        menuStore.settingsDidChange = { [weak self] in
            self?.dashboardCoordinator.settingsChanged()
        }
        menuStore.metricsDidChange = { [weak self] in
            self?.dashboardCoordinator.refreshMetrics()
        }
        dashboardCoordinator.stateDidChange = { [weak self] state in
            self?.menuStore.setDashboardOpen(state != .stopped)
            AppActivationPolicy.hideDockIconIfNoManagedWindowIsVisible()
        }
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        "https://www.chunyangwen.com/CodexDashboard/appcast.xml"
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        statusItemController?.dismissPopover()
        return productTerminationGate.applicationShouldTerminate(
            helperState: dashboardCoordinator.state,
            terminateHelper: { [weak self] completion in
                self?.dashboardCoordinator.terminateForHostQuit(completion: completion)
            },
            reply: {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        requestDashboard()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sparkle is kept out of the always-running menu-bar baseline. The
        // updater and its background work are created only when requested.
        AppUpdater.shared.configure { [weak self] in
            self?.checkForUpdates()
        }

        NSApp.setActivationPolicy(.accessory)
        statusItemController = StatusItemController(
            store: menuStore,
            defaults: DashboardPreferences.sharedDefaults(),
            commandHandler: { [weak self] command in self?.handlePopoverCommand(command) }
        )
        menuStore.startMenuBarMonitoring()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        requestDashboard()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    private func checkForUpdates() {
        if updaterController == nil {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: self,
                userDriverDelegate: self
            )
        }

        let updater = updaterController.updater
        guard !updateCheckInProgress,
              updater.canCheckForUpdates,
              !updater.sessionInProgress else { return }

        // Sparkle's standard driver presents modal UI in the host process.
        // Activate it explicitly so that UI is not left behind the helper.
        updateCheckInProgress = true
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        guard updateCheckInProgress else { return }
        updateCheckInProgress = false
    }

    private func requestProductQuit() {
        statusItemController?.dismissPopover()
        productTerminationGate.requestFromHelper(
            helperState: dashboardCoordinator.state,
            terminateHelper: { [weak self] completion in
                self?.dashboardCoordinator.terminateForHostQuit(completion: completion)
            },
            terminateHost: {
                NSApp.terminate(nil)
            }
        )
    }

    private func handleHelperCommand(_ command: DashboardLifecycleCommand) {
        switch command {
        case .openSettings:
            openSettingsWindow()
        case .checkForUpdates:
            AppUpdater.shared.checkForUpdates()
        case .quitProduct:
            requestProductQuit()
        case .ready, .helperClosing, .focus, .refreshMetrics, .rebuildHistoryIndex, .settingsChanged:
            break
        }
    }

    private func handlePopoverCommand(_ command: MenuBarPopoverCommand) {
        switch command {
        case .openDashboard:
            requestDashboard()
        case .quitProduct:
            requestProductQuit()
        }
    }

    private func openSettingsWindow() {
        AppActivationPolicy.showDockIcon()
        guard let settingsItem = NSApp.mainMenu?.items
            .compactMap(\.submenu)
            .flatMap(\.items)
            .first(where: { $0.title.localizedCaseInsensitiveContains("Settings") }),
              let target = settingsItem.target else { return }
        _ = target.perform(settingsItem.action, with: settingsItem)
        AppActivationPolicy.bringWindowToFront(identifier: .settings)
    }

    private func requestDashboard() {
        CodexMemoryTrace.mark("host.dashboard-request.begin")
        statusItemController?.dismissPopover()
        CodexMemoryTrace.mark("host.dashboard-request.after-popover-release")
        dashboardCoordinator.requestDashboard()
        CodexMemoryTrace.mark("host.dashboard-request.after-helper-request")
    }

    @objc private func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            AppActivationPolicy.hideDockIconIfNoManagedWindowIsVisible()
        }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        _ = notification
    }
}

@MainActor
private enum AppActivationPolicy {
    static let managedWindowIdentifiers: Set<NSUserInterfaceItemIdentifier> = [.settings]

    static func showDockIcon() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    static func bringWindowToFront(
        identifier: NSUserInterfaceItemIdentifier
    ) {
        showDockIcon()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        bringWindowToFront(identifier: identifier, attemptsRemaining: 20)
    }

    private static func bringWindowToFront(
        identifier: NSUserInterfaceItemIdentifier,
        attemptsRemaining: Int
    ) {
        showDockIcon()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)

        let targetWindow = NSApp.windows.first { window in
            if window.identifier == identifier { return true }
            if identifier == .settings && window.title.contains("Settings") { return true }
            return false
        }

        guard let window = targetWindow else {
            guard attemptsRemaining > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                bringWindowToFront(identifier: identifier, attemptsRemaining: attemptsRemaining - 1)
            }
            return
        }

        window.identifier = identifier
        NSApp.unhide(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil as Any?)
        }
        window.makeKeyAndOrderFront(nil as Any?)
        window.orderFrontRegardless()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
    }

    static func hideDockIconIfNoManagedWindowIsVisible() {
        guard isMenuBarIconEnabled else {
            showDockIcon()
            return
        }

        let hasVisibleManagedWindow = NSApp.windows.contains { window in
            let isManaged = (window.identifier.map { managedWindowIdentifiers.contains($0) } ?? false)
                || window.title.contains("Settings")
            return isManaged && window.isVisible
        }
        if !hasVisibleManagedWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private static var isMenuBarIconEnabled: Bool {
        let defaults = DashboardPreferences.sharedDefaults()
        return defaults.object(forKey: DashboardPreferences.showMenuBarIconKey) == nil
            || defaults.bool(forKey: DashboardPreferences.showMenuBarIconKey)
    }
}

private struct AppWindowIdentifier: NSViewRepresentable {
    let identifier: NSUserInterfaceItemIdentifier

    func makeNSView(context: Context) -> NSView {
        WindowIdentifyingNSView(identifier: identifier)
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private final class WindowIdentifyingNSView: NSView {
    private let appWindowIdentifier: NSUserInterfaceItemIdentifier

    init(identifier: NSUserInterfaceItemIdentifier) {
        appWindowIdentifier = identifier
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            window.identifier = appWindowIdentifier
            if window.isVisible {
                AppActivationPolicy.showDockIcon()
            }
        } else {
            DispatchQueue.main.async {
                AppActivationPolicy.hideDockIconIfNoManagedWindowIsVisible()
            }
        }
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let dashboard = Self("CodexDashboard.dashboard")
    static let conversation = Self("CodexDashboard.conversation")
    static let settings = Self("CodexDashboard.settings")
}

enum MenuBarQuotaIconStyle: String, CaseIterable, Identifiable {
    case rings
    case droplet
    case capsules
    case twoRows

    var id: String { rawValue }
    var statusItemLength: CGFloat {
        self == .twoRows ? NSStatusItem.variableLength : NSStatusItem.squareLength
    }

    var label: String {
        switch self {
        case .rings: "Concentric rings"
        case .droplet: "Split droplet"
        case .capsules: "Two capsules"
        case .twoRows: "Two rows"
        }
    }
}

@main
private struct CodexDashboardApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            DashboardSettingsView()
                .environmentObject(appDelegate.menuStore)
                .background(AppWindowIdentifier(identifier: .settings))
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink()
            }
        }
    }
}

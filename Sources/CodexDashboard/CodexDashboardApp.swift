import AppKit
import CodexMetricsCore
import ServiceManagement
import SwiftUI

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard
            let window = notification.object as? NSWindow,
            let identifier = window.identifier,
            AppActivationPolicy.managedWindowIdentifiers.contains(identifier)
        else { return }

        DispatchQueue.main.async {
            AppActivationPolicy.hideDockIconIfNoManagedWindowIsVisible()
        }
    }
}

@MainActor
private enum AppActivationPolicy {
    static let managedWindowIdentifiers: Set<NSUserInterfaceItemIdentifier> = [.dashboard, .settings]

    static func showDockIcon() {
        NSApp.setActivationPolicy(.regular)
    }

    static func dismissMenuBarExtra() {
        guard
            let window = NSApp.keyWindow,
            window.identifier.map({ !managedWindowIdentifiers.contains($0) }) ?? true
        else { return }

        window.orderOut(nil)
    }

    static func bringWindowToFront(
        identifier: NSUserInterfaceItemIdentifier
    ) {
        // Let the menu-bar popover resign key status before promoting the app window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            bringWindowToFront(identifier: identifier, attemptsRemaining: 8)
        }
    }

    private static func bringWindowToFront(
        identifier: NSUserInterfaceItemIdentifier,
        attemptsRemaining: Int
    ) {
        guard let window = NSApp.windows.first(where: { $0.identifier == identifier }) else {
            guard attemptsRemaining > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                bringWindowToFront(identifier: identifier, attemptsRemaining: attemptsRemaining - 1)
            }
            return
        }

        showDockIcon()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    static func hideDockIconIfNoManagedWindowIsVisible() {
        guard isMenuBarIconEnabled else {
            showDockIcon()
            return
        }

        let hasVisibleManagedWindow = NSApp.windows.contains { window in
            guard let identifier = window.identifier else { return false }
            return window.isVisible && managedWindowIdentifiers.contains(identifier)
        }
        if !hasVisibleManagedWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private static var isMenuBarIconEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "showMenuBarIcon") == nil || defaults.bool(forKey: "showMenuBarIcon")
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
        }
        if window?.isVisible == true {
            AppActivationPolicy.showDockIcon()
        }
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let dashboard = Self("CodexDashboard.dashboard")
    static let settings = Self("CodexDashboard.settings")
}

@main
struct CodexDashboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DashboardStore()
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        Window("Codex Dashboard", id: "dashboard") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1060, minHeight: 700)
                .background(AppWindowIdentifier(identifier: .dashboard))
                .task { store.load() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Metrics") { store.load() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra("Codex Dashboard", systemImage: "chart.bar.xaxis", isInserted: $showMenuBarIcon) {
            MenuBarDashboardView()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            DashboardSettingsView()
                .environmentObject(store)
                .background(AppWindowIdentifier(identifier: .settings))
        }
        .defaultSize(width: 520, height: 420)
    }
}

private struct MenuBarDashboardView: View {
    @EnvironmentObject private var store: DashboardStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header

            if let windows = store.subscription?.windows, !windows.isEmpty {
                Divider()
                VStack(spacing: 14) {
                    ForEach(windows) { quotaRow($0) }
                }
                .padding(16)
            }

            Divider()
            todayMetrics.padding(16)

            Divider()
            HStack(spacing: 8) {
                Button("Open Dashboard") {
                    AppActivationPolicy.dismissMenuBarExtra()
                    AppActivationPolicy.showDockIcon()
                    openWindow(id: "dashboard")
                    AppActivationPolicy.bringWindowToFront(identifier: .dashboard)
                }
                .buttonStyle(.borderedProminent)

                Button { store.load() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh now")
                    .disabled(store.isBusy)

                Spacer()

                Menu {
                    Button("Settings…") {
                        AppActivationPolicy.dismissMenuBarExtra()
                        AppActivationPolicy.showDockIcon()
                        openSettings()
                        AppActivationPolicy.bringWindowToFront(identifier: .settings)
                    }
                    .keyboardShortcut(",", modifiers: .command)
                    Divider()
                    Button("Quit Codex Dashboard") { NSApp.terminate(nil) }
                        .keyboardShortcut("q", modifiers: .command)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
            }
            .padding(12)
        }
        .frame(width: 350)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(store.account?.email ?? "Codex Dashboard")
                    .font(.headline)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(planLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isBusy { ProgressView().controlSize(.small) }
        }
        .padding(16)
    }

    private var planLabel: String {
        if let plan = store.subscription?.displayPlan { return "ChatGPT \(plan)" }
        if let plan = store.account?.planType { return "ChatGPT \(plan.capitalized)" }
        return "Plan not reported"
    }

    private func quotaRow(_ window: UsageQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(window.displayName).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(window.remainingPercent.formatted(.number.precision(.fractionLength(0))))% left")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(100, max(0, window.usedPercent)), total: 100)
                .tint(window.usedPercent >= 90 ? .orange : .accentColor)
            Text("Resets \(window.resetsAt, style: .relative)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }

    private var todayMetrics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TODAY")
                .font(.caption2.weight(.bold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
            Grid(horizontalSpacing: 18, verticalSpacing: 12) {
                GridRow {
                    menuMetric("Estimated cost", MetricFormatters.preciseCurrency(store.todayEstimatedCost), "dollarsign.circle")
                    menuMetric("Tokens", MetricFormatters.compactNumber(store.todayUsage.total), "text.word.spacing")
                }
                GridRow {
                    menuMetric("Tools", store.todayToolCalls.formatted(), "wrench.and.screwdriver")
                    menuMetric("Skills", store.todaySkillCalls.formatted(), "sparkles")
                }
            }
        }
    }

    private func menuMetric(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.subheadline.monospacedDigit().weight(.semibold))
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DashboardSettingsView: View {
    @EnvironmentObject private var store: DashboardStore
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, isEnabled in
                        updateLaunchAtLogin(isEnabled)
                    }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                LabeledContent("Refresh metrics") {
                    Picker("Refresh metrics", selection: refreshBinding) {
                        Text("Manually").tag(TimeInterval(0))
                        Text("Every 15 seconds").tag(TimeInterval(15))
                        Text("Every minute").tag(TimeInterval(60))
                        Text("Every 5 minutes").tag(TimeInterval(300))
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
            }

            Section("Codex data") {
                LabeledContent("Location") {
                    Text(store.codexHome.path(percentEncoded: false))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(store.codexHome.path(percentEncoded: false))
                }
                HStack {
                    Button("Choose…") { chooseCodexHome() }
                    Button("Reveal in Finder") { NSWorkspace.shared.open(store.codexHome) }
                    Spacer()
                    Button("Use Default") { store.resetCodexHome() }
                        .disabled(store.codexHome.standardizedFileURL == defaultCodexHome.standardizedFileURL)
                }
                Text("Codex Dashboard reads local session, account, and quota metadata from this folder. Credentials never leave your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(4)
    }

    private var refreshBinding: Binding<TimeInterval> {
        Binding(
            get: { store.refreshInterval },
            set: { newValue in store.updateRefreshInterval(newValue) }
        )
    }

    private var defaultCodexHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    private func chooseCodexHome() {
        let panel = NSOpenPanel()
        panel.title = "Choose Codex Data Folder"
        panel.prompt = "Choose"
        panel.directoryURL = store.codexHome
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.updateCodexHome(url)
    }

    private func updateLaunchAtLogin(_ isEnabled: Bool) {
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

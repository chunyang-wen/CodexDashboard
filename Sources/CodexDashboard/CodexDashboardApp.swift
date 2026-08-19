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
    static let managedWindowIdentifiers: Set<NSUserInterfaceItemIdentifier> = [.dashboard, .conversation, .settings]

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
    static let conversation = Self("CodexDashboard.conversation")
    static let settings = Self("CodexDashboard.settings")
}

private enum MenuBarQuotaIconStyle: String, CaseIterable, Identifiable {
    case rings
    case droplet
    case capsules

    var id: String { rawValue }
    var label: String {
        switch self {
        case .rings: "Concentric rings"
        case .droplet: "Split droplet"
        case .capsules: "Two capsules"
        }
    }
}

@main
struct CodexDashboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DashboardStore()
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("menuBarQuotaIconStyle") private var menuBarQuotaIconStyle = MenuBarQuotaIconStyle.rings.rawValue

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

        WindowGroup("Conversation Debugger", for: ConversationWindowRequest.self) { $request in
            if let request {
                ConversationDebuggerWindow(request: request)
                    .background(AppWindowIdentifier(identifier: .conversation))
            } else {
                ContentUnavailableView("No conversation selected", systemImage: "text.bubble")
                    .background(AppWindowIdentifier(identifier: .conversation))
            }
        }
        .defaultSize(width: 980, height: 760)
        .windowResizability(.contentMinSize)

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarDashboardView()
                .environmentObject(store)
        } label: {
            MenuBarQuotaIcon(windows: menuBarQuotaWindows, style: resolvedMenuBarQuotaIconStyle)
        }
        .menuBarExtraStyle(.window)

        Settings {
            DashboardSettingsView()
                .environmentObject(store)
                .background(AppWindowIdentifier(identifier: .settings))
        }
        .defaultSize(width: 520, height: 420)
    }

    private var menuBarQuotaWindows: [UsageQuotaWindow] {
        store.subscription?.windows.sorted { $0.windowMinutes < $1.windowMinutes } ?? []
    }

    private var resolvedMenuBarQuotaIconStyle: MenuBarQuotaIconStyle {
        MenuBarQuotaIconStyle(rawValue: menuBarQuotaIconStyle) ?? .rings
    }
}

private struct MenuBarQuotaIcon: View {
    let windows: [UsageQuotaWindow]
    let style: MenuBarQuotaIconStyle

    var body: some View {
        Image(nsImage: statusImage)
            .renderingMode(.template)
            .interpolation(.none)
            .frame(width: 18, height: 18)
            .accessibilityLabel("Codex quota")
            .accessibilityValue(accessibilityValue)
            .help(accessibilityValue)
    }

    private var statusImage: NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 36,
            pixelsHigh: 36,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            image.isTemplate = true
            return image
        }
        representation.size = size
        image.addRepresentation(representation)

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: representation) {
            NSGraphicsContext.current = context
            context.cgContext.setShouldAntialias(true)
            switch style {
            case .rings: drawRings()
            case .droplet: drawDroplet()
            case .capsules: drawCapsules()
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        image.isTemplate = true
        return image
    }

    private var primaryWindow: UsageQuotaWindow? {
        windows.first(where: { $0.windowMinutes == 300 })
    }

    private var weeklyWindow: UsageQuotaWindow? {
        windows.first(where: { $0.windowMinutes == 10_080 })
    }

    private func drawRings() {
        drawRing(radius: 6.8, lineWidth: 2.4, window: weeklyWindow)
        drawRing(radius: 3.2, lineWidth: 1.8, window: primaryWindow)
    }

    private func drawRing(radius: CGFloat, lineWidth: CGFloat, window: UsageQuotaWindow?) {
        let center = NSPoint(x: 9, y: 9)
        let rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = lineWidth
        NSColor.black.withAlphaComponent(window == nil ? 0.12 : 0.2).setStroke()
        track.stroke()

        guard let fraction = remainingFraction(for: window), fraction > 0 else { return }
        let progress: NSBezierPath
        if fraction >= 0.999 {
            progress = NSBezierPath(ovalIn: rect)
        } else {
            progress = NSBezierPath()
            progress.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: 90 - 360 * fraction,
                clockwise: true
            )
        }
        progress.lineWidth = lineWidth
        progress.lineCapStyle = .butt
        NSColor.black.setStroke()
        progress.stroke()
    }

    private func drawDroplet() {
        let left = dropletChamber(left: true)
        let right = dropletChamber(left: false)
        drawLiquid(in: left, bounds: NSRect(x: 1.7, y: 2, width: 6.65, height: 14), window: primaryWindow)
        drawLiquid(in: right, bounds: NSRect(x: 9.65, y: 2, width: 6.65, height: 14), window: weeklyWindow)
    }

    private func dropletChamber(left: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        if left {
            path.move(to: NSPoint(x: 8.35, y: 16))
            path.curve(to: NSPoint(x: 1.7, y: 7), controlPoint1: NSPoint(x: 6.2, y: 13.8), controlPoint2: NSPoint(x: 1.7, y: 10.2))
            path.curve(to: NSPoint(x: 8.35, y: 2), controlPoint1: NSPoint(x: 1.7, y: 3.2), controlPoint2: NSPoint(x: 4.8, y: 2))
        } else {
            path.move(to: NSPoint(x: 9.65, y: 16))
            path.curve(to: NSPoint(x: 16.3, y: 7), controlPoint1: NSPoint(x: 11.8, y: 13.8), controlPoint2: NSPoint(x: 16.3, y: 10.2))
            path.curve(to: NSPoint(x: 9.65, y: 2), controlPoint1: NSPoint(x: 16.3, y: 3.2), controlPoint2: NSPoint(x: 13.2, y: 2))
        }
        path.close()
        return path
    }

    private func drawLiquid(in chamber: NSBezierPath, bounds: NSRect, window: UsageQuotaWindow?) {
        NSColor.black.withAlphaComponent(0.1).setFill()
        chamber.fill()
        if let fraction = remainingFraction(for: window), fraction > 0 {
            NSGraphicsContext.current?.cgContext.saveGState()
            chamber.addClip()
            NSColor.black.setFill()
            NSBezierPath(rect: NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height * fraction)).fill()
            NSGraphicsContext.current?.cgContext.restoreGState()
        }
        chamber.lineWidth = 1
        NSColor.black.withAlphaComponent(window == nil ? 0.3 : 0.72).setStroke()
        chamber.stroke()
    }

    private func drawCapsules() {
        drawCapsule(in: NSRect(x: 1.5, y: 9, width: 15, height: 6), window: primaryWindow)
        drawCapsule(in: NSRect(x: 1.5, y: 3, width: 15, height: 4), window: weeklyWindow)
    }

    private func drawCapsule(in rect: NSRect, window: UsageQuotaWindow?) {
        let radius = rect.height / 2
        let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.black.withAlphaComponent(0.16).setFill()
        track.fill()
        if let fraction = remainingFraction(for: window), fraction > 0 {
            NSGraphicsContext.current?.cgContext.saveGState()
            track.addClip()
            NSColor.black.setFill()
            NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height)).fill()
            NSGraphicsContext.current?.cgContext.restoreGState()
        }
        let stroke = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: max(0, radius - 0.5),
            yRadius: max(0, radius - 0.5)
        )
        stroke.lineWidth = 1
        NSColor.black.withAlphaComponent(window == nil ? 0.3 : 0.48).setStroke()
        stroke.stroke()
    }

    private func remainingFraction(for window: UsageQuotaWindow?) -> CGFloat? {
        window.map { CGFloat(min(100, max(0, $0.remainingPercent)) / 100) }
    }

    private var accessibilityValue: String {
        let displayedWindows = [primaryWindow, weeklyWindow].compactMap { $0 }
        guard !displayedWindows.isEmpty else { return "Quota unavailable" }
        return displayedWindows.map { window in
            "\(window.displayName): \(window.remainingPercent.formatted(.number.precision(.fractionLength(0))))% remaining"
        }.joined(separator: ", ")
    }
}

private struct MenuBarDashboardView: View {
    @EnvironmentObject private var store: DashboardStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: [Color.teal.opacity(0.08), .clear, Color.mint.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 0) {
                header

                if let windows = store.subscription?.windows, !windows.isEmpty {
                    sectionDivider
                    VStack(spacing: 16) {
                        ForEach(windows) { quotaRow($0) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 15)
                }

                sectionDivider
                todayMetrics.padding(16)

                sectionDivider
                HStack(spacing: 12) {
                    Spacer()
                    MenuBarActionButton(
                        title: "Open Dashboard",
                        systemImage: "rectangle.grid.2x2.fill",
                        tint: .teal
                    ) {
                        AppActivationPolicy.dismissMenuBarExtra()
                        AppActivationPolicy.showDockIcon()
                        openWindow(id: "dashboard")
                        AppActivationPolicy.bringWindowToFront(identifier: .dashboard)
                    }
                    MenuBarActionButton(
                        title: "Settings",
                        systemImage: "gearshape.fill"
                    ) {
                        AppActivationPolicy.dismissMenuBarExtra()
                        AppActivationPolicy.showDockIcon()
                        openSettings()
                        AppActivationPolicy.bringWindowToFront(identifier: .settings)
                    }
                    .keyboardShortcut(",", modifiers: .command)
                    MenuBarActionButton(
                        title: "Quit Codex Dashboard",
                        systemImage: "power",
                        tint: .red
                    ) {
                        NSApp.terminate(nil)
                    }
                    .keyboardShortcut("q", modifiers: .command)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.035))
            }
        }
        .frame(width: 350)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(.separator.opacity(0.5))
            .frame(height: 0.5)
    }

    private var header: some View {
        HStack(spacing: 12) {
            MenuBarAppIcon(statusColor: headerQuotaColor)
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

    private var headerQuotaColor: Color? {
        store.subscription?.windows
            .map(\.remainingPercent)
            .min()
            .map { quotaColor(for: $0) }
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
                Text("\(window.remainingPercent.formatted(.number.precision(.fractionLength(0))))% remaining")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }
            QuotaRemainingBar(remainingPercent: window.remainingPercent)
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

private struct QuotaRemainingBar: View {
    let remainingPercent: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double {
        min(1, max(0, remainingPercent / 100))
    }

    private var color: Color { quotaColor(for: remainingPercent) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.72), color],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * fraction)
                    .shadow(color: color.opacity(0.2), radius: 3)
            }
        }
        .frame(height: 6)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Quota remaining")
        .accessibilityValue(remainingPercent.formatted(.percent.scale(1).precision(.fractionLength(0))))
    }
}

private func quotaColor(for remainingPercent: Double) -> Color {
    switch remainingPercent {
    case ...10: .red
    case ...25: .orange
    default: .teal
    }
}

private struct MenuBarAppIcon: View {
    let statusColor: Color?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 3, y: 1.5)

            if let statusColor {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .overlay {
                        Circle().stroke(Color.black.opacity(0.22), lineWidth: 0.5)
                    }
                    .padding(2)
                    .background(.ultraThickMaterial, in: Circle())
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }
}

private struct MenuBarActionButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isHovering ? tint : Color.secondary)
                .frame(width: 36, height: 30)
                .background(
                    isHovering ? tint.opacity(0.13) : Color.primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.primary.opacity(isHovering ? 0.11 : 0.07), lineWidth: 0.5)
                }
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct DashboardSettingsView: View {
    @EnvironmentObject private var store: DashboardStore
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("menuBarQuotaIconStyle") private var menuBarQuotaIconStyle = MenuBarQuotaIconStyle.rings.rawValue
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
                LabeledContent("Quota icon") {
                    Picker("Quota icon", selection: $menuBarQuotaIconStyle) {
                        ForEach(MenuBarQuotaIconStyle.allCases) { style in
                            HStack(spacing: 8) {
                                MenuBarQuotaIcon(windows: quotaIconPreviewWindows, style: style)
                                    .accessibilityHidden(true)
                                Text(style.label)
                            }
                            .tag(style.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
                .disabled(!showMenuBarIcon)
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

    private var quotaIconPreviewWindows: [UsageQuotaWindow] {
        store.subscription?.windows.sorted { $0.windowMinutes < $1.windowMinutes } ?? []
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

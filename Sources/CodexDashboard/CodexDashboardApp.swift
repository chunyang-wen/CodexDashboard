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
        AppActivationPolicy.showDockIcon()
        startHandler?()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private var updaterController: SPUStandardUpdaterController!

    nonisolated var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        "https://www.chunyangwen.com/CodexDashboard/appcast.xml"
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sparkle is kept out of the always-running menu-bar baseline. The
        // updater and its background work are created only when requested.
        AppUpdater.shared.configure { [weak self] in
            self?.checkForUpdates()
        }

        NSApp.setActivationPolicy(.regular)
        AppActivationPolicy.bringWindowToFront(identifier: .dashboard)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
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
        updaterController.checkForUpdates(nil)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            AppActivationPolicy.hideDockIconIfNoManagedWindowIsVisible()
            AppActivationPolicy.releaseDashboardMemoryIfHidden()
        }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window.identifier == .dashboard || window.title == "Codex Dashboard" {
            AppActivationPolicy.dashboardStore?.activateDashboard()
        }
    }
}

@MainActor
private enum AppActivationPolicy {
    static let managedWindowIdentifiers: Set<NSUserInterfaceItemIdentifier> = [.dashboard, .conversation, .settings]
    static weak var dashboardStore: DashboardStore?

    static func configure(store: DashboardStore) {
        dashboardStore = store
    }

    static func showDockIcon() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    static func dismissMenuBarExtra() {
        guard
            let window = NSApp.keyWindow,
            window.identifier.map({ !managedWindowIdentifiers.contains($0) }) ?? true,
            window.title != "Codex Dashboard"
        else { return }

        window.orderOut(nil)
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
            if identifier == .dashboard && window.title == "Codex Dashboard" { return true }
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
                || window.title == "Codex Dashboard"
                || window.title.contains("Settings")
            return isManaged && window.isVisible
        }
        if !hasVisibleManagedWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    static func releaseDashboardMemoryIfHidden() {
        let dashboardIsVisible = NSApp.windows.contains { window in
            let isDashboard = window.identifier == .dashboard || window.title == "Codex Dashboard"
            return isDashboard && window.isVisible
        }
        if !dashboardIsVisible {
            dashboardStore?.releaseDashboardMemory()
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

/// Removes the dashboard's SwiftUI/Charts render tree while its window is closed.
/// Keeping an invisible hosting tree alive costs considerably more than the small
/// menu-bar interface, even after its data model has been emptied.
private struct DashboardWindowRoot: View {
    @EnvironmentObject private var store: DashboardStore

    @ViewBuilder var body: some View {
        if store.dashboardDataIsResident {
            ContentView()
                .onDisappear {
                    AppActivationPolicy.releaseDashboardMemoryIfHidden()
                }
        } else {
            Color.clear
        }
    }
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
                AppActivationPolicy.releaseDashboardMemoryIfHidden()
            }
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
private struct CodexDashboardApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: DashboardStore
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("menuBarQuotaIconStyle") private var menuBarQuotaIconStyle = MenuBarQuotaIconStyle.rings.rawValue
    @AppStorage("showQuotaAlertMarker") private var showQuotaAlertMarker = false
    // Keep the original defaults key so existing marker values retain their meaning after this correction.
    @AppStorage("quotaAlertUsedPercent") private var quotaAlertRemainingPercent = 80.0

    init() {
        let store = DashboardStore()
        _store = StateObject(wrappedValue: store)
        AppActivationPolicy.configure(store: store)
        store.loadMenuBar()
    }

    var body: some Scene {
        Window("Codex Dashboard", id: "dashboard") {
            DashboardWindowRoot()
                .environmentObject(store)
                .frame(minWidth: 1060, minHeight: 700)
                .background(AppWindowIdentifier(identifier: .dashboard))
                .task { store.activateDashboard() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    AppUpdater.shared.checkForUpdates()
                }
            }
            CommandGroup(after: .newItem) {
                Button("Refresh Metrics") { store.load() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit Codex Dashboard") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
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

        MenuBarExtra(isInserted: menuBarExtraIsInserted) {
            MenuBarDashboardView()
                .environmentObject(store)
        } label: {
            MenuBarQuotaIcon(
                windows: menuBarQuotaWindows,
                style: resolvedMenuBarQuotaIconStyle,
                alertRemainingPercent: showQuotaAlertMarker ? quotaAlertRemainingPercent : nil
            )
            .equatable()
            .background(InitialDashboardOpener())
        }
        .menuBarExtraStyle(.window)

        Settings {
            DashboardSettingsView()
                .environmentObject(store)
                .background(AppWindowIdentifier(identifier: .settings))
        }
        .defaultSize(width: 520, height: 420)
    }

    private var menuBarExtraIsInserted: Binding<Bool> {
        Binding(
            get: { showMenuBarIcon },
            set: { showMenuBarIcon = $0 }
        )
    }

    private var menuBarQuotaWindows: [UsageQuotaWindow] {
        store.subscription?.windows.sorted { $0.windowMinutes < $1.windowMinutes } ?? []
    }

    private var resolvedMenuBarQuotaIconStyle: MenuBarQuotaIconStyle {
        MenuBarQuotaIconStyle(rawValue: menuBarQuotaIconStyle) ?? .rings
    }
}

@MainActor
private enum InitialDashboardPresentation {
    static var wasRequested = false
}

/// A `Window` scene remembers that it was closed across debug launches. The
/// menu-bar label is always instantiated, so use it to request the dashboard
/// exactly once per process and preserve the app's launch contract.
private struct InitialDashboardOpener: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                guard !InitialDashboardPresentation.wasRequested else { return }
                InitialDashboardPresentation.wasRequested = true
                openWindow(id: "dashboard")
                AppActivationPolicy.bringWindowToFront(identifier: .dashboard)
            }
    }
}

@MainActor
private enum MenuBarQuotaIconRenderer {
    struct Key: Hashable {
        let windows: [UsageQuotaWindow]
        let style: MenuBarQuotaIconStyle
        let alertRemainingPercent: Double?
    }

    private static var cachedKey: Key?
    private static var cachedImage: NSImage?

    static func image(
        windows: [UsageQuotaWindow],
        style: MenuBarQuotaIconStyle,
        alertRemainingPercent: Double?
    ) -> NSImage {
        let key = Key(windows: windows, style: style, alertRemainingPercent: alertRemainingPercent)
        if let cachedImage, cachedKey == key {
            return cachedImage
        }
        let rendered = render(windows: windows, style: style, alertRemainingPercent: alertRemainingPercent)
        cachedKey = key
        cachedImage = rendered
        return rendered
    }

    private static func render(
        windows: [UsageQuotaWindow],
        style: MenuBarQuotaIconStyle,
        alertRemainingPercent: Double?
    ) -> NSImage {
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

        let primaryWindow = windows
            .filter { $0.windowMinutes != 10_080 }
            .min { $0.windowMinutes < $1.windowMinutes }
        let weeklyWindow = windows.first(where: { $0.windowMinutes == 10_080 })
        let iconInk: NSColor = alertRemainingPercent == nil ? .black : .labelColor

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: representation) {
            NSGraphicsContext.current = context
            context.cgContext.setShouldAntialias(true)
            switch style {
            case .rings: drawRings(weeklyWindow: weeklyWindow, primaryWindow: primaryWindow, iconInk: iconInk)
            case .droplet: drawDroplet(weeklyWindow: weeklyWindow, primaryWindow: primaryWindow, iconInk: iconInk)
            case .capsules: drawCapsules(weeklyWindow: weeklyWindow, primaryWindow: primaryWindow, iconInk: iconInk)
            }
            drawAlertMarker(style: style, alertRemainingPercent: alertRemainingPercent, weeklyWindow: weeklyWindow, primaryWindow: primaryWindow)
        }
        NSGraphicsContext.restoreGraphicsState()

        image.isTemplate = alertRemainingPercent == nil
        return image
    }

    private static func drawRings(weeklyWindow: UsageQuotaWindow?, primaryWindow: UsageQuotaWindow?, iconInk: NSColor) {
        drawRing(radius: 6.8, lineWidth: 2.4, window: weeklyWindow, iconInk: iconInk)
        drawRing(radius: 3.2, lineWidth: 1.8, window: primaryWindow, iconInk: iconInk)
    }

    private static func drawRing(radius: CGFloat, lineWidth: CGFloat, window: UsageQuotaWindow?, iconInk: NSColor) {
        let center = NSPoint(x: 9, y: 9)
        let rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = lineWidth
        iconInk.withAlphaComponent(window == nil ? 0.12 : 0.2).setStroke()
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
        iconInk.setStroke()
        progress.stroke()
    }

    private static func drawDroplet(weeklyWindow: UsageQuotaWindow?, primaryWindow: UsageQuotaWindow?, iconInk: NSColor) {
        let left = dropletChamber(left: true)
        let right = dropletChamber(left: false)
        drawLiquid(in: left, bounds: NSRect(x: 1.7, y: 2, width: 6.65, height: 14), window: weeklyWindow, iconInk: iconInk)
        drawLiquid(in: right, bounds: NSRect(x: 9.65, y: 2, width: 6.65, height: 14), window: primaryWindow, iconInk: iconInk)
    }

    private static func dropletChamber(left: Bool) -> NSBezierPath {
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

    private static func drawLiquid(in chamber: NSBezierPath, bounds: NSRect, window: UsageQuotaWindow?, iconInk: NSColor) {
        iconInk.withAlphaComponent(0.1).setFill()
        chamber.fill()
        if let fraction = remainingFraction(for: window), fraction > 0 {
            NSGraphicsContext.current?.cgContext.saveGState()
            chamber.addClip()
            iconInk.setFill()
            NSBezierPath(rect: NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height * fraction)).fill()
            NSGraphicsContext.current?.cgContext.restoreGState()
        }
        chamber.lineWidth = 1
        iconInk.withAlphaComponent(window == nil ? 0.3 : 0.72).setStroke()
        chamber.stroke()
    }

    private static func drawCapsules(weeklyWindow: UsageQuotaWindow?, primaryWindow: UsageQuotaWindow?, iconInk: NSColor) {
        drawCapsule(in: NSRect(x: 1.5, y: 9, width: 15, height: 6), window: weeklyWindow, iconInk: iconInk)
        drawCapsule(in: NSRect(x: 1.5, y: 3, width: 15, height: 4), window: primaryWindow, iconInk: iconInk)
    }

    private static func drawCapsule(in rect: NSRect, window: UsageQuotaWindow?, iconInk: NSColor) {
        let radius = rect.height / 2
        let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        iconInk.withAlphaComponent(0.16).setFill()
        track.fill()
        if let fraction = remainingFraction(for: window), fraction > 0 {
            NSGraphicsContext.current?.cgContext.saveGState()
            track.addClip()
            iconInk.setFill()
            NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height)).fill()
            NSGraphicsContext.current?.cgContext.restoreGState()
        }
        let stroke = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: max(0, radius - 0.5),
            yRadius: max(0, radius - 0.5)
        )
        stroke.lineWidth = 1
        iconInk.withAlphaComponent(window == nil ? 0.3 : 0.48).setStroke()
        stroke.stroke()
    }

    private static func drawAlertMarker(
        style: MenuBarQuotaIconStyle,
        alertRemainingPercent: Double?,
        weeklyWindow: UsageQuotaWindow?,
        primaryWindow: UsageQuotaWindow?
    ) {
        guard let alertRemainingPercent else { return }
        let fraction = CGFloat(min(100, max(0, alertRemainingPercent)) / 100)
        switch style {
        case .rings:
            let angle = CGFloat.pi / 2 - 2 * .pi * fraction
            if weeklyWindow != nil {
                drawAlertDot(at: NSPoint(x: 9 + 6.8 * cos(angle), y: 9 + 6.8 * sin(angle)), diameter: 4)
            }
            if primaryWindow != nil {
                drawAlertDot(at: NSPoint(x: 9 + 3.2 * cos(angle), y: 9 + 3.2 * sin(angle)), diameter: 3.2)
            }
        case .droplet:
            let y = 2 + 14 * fraction
            if weeklyWindow != nil {
                drawAlertBar(y: y, from: 1.5, to: 8.5, clippedTo: dropletChamber(left: true))
            }
            if primaryWindow != nil {
                drawAlertBar(y: y, from: 9.5, to: 16.5, clippedTo: dropletChamber(left: false))
            }
        case .capsules:
            let x = 1.5 + 15 * fraction
            if weeklyWindow != nil {
                drawAlertDot(at: NSPoint(x: x, y: 12), diameter: 4)
            }
            if primaryWindow != nil {
                drawAlertDot(at: NSPoint(x: x, y: 5), diameter: 3.4)
            }
        }
    }

    private static func drawAlertDot(at center: NSPoint, diameter: CGFloat) {
        let rect = NSRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    private static func drawAlertBar(y: CGFloat, from startX: CGFloat, to endX: CGFloat, clippedTo clip: NSBezierPath) {
        NSGraphicsContext.current?.cgContext.saveGState()
        clip.addClip()
        let bar = NSBezierPath()
        bar.move(to: NSPoint(x: startX, y: y))
        bar.line(to: NSPoint(x: endX, y: y))
        bar.lineWidth = 1.4
        bar.lineCapStyle = .round
        NSColor.systemRed.setStroke()
        bar.stroke()
        NSGraphicsContext.current?.cgContext.restoreGState()
    }

    private static func remainingFraction(for window: UsageQuotaWindow?) -> CGFloat? {
        window.map { CGFloat(min(100, max(0, $0.remainingPercent)) / 100) }
    }
}

private struct MenuBarQuotaIcon: View, Equatable {
    let windows: [UsageQuotaWindow]
    let style: MenuBarQuotaIconStyle
    var alertRemainingPercent: Double? = nil

    var body: some View {
        Image(nsImage: statusImage)
            .renderingMode(alertRemainingPercent == nil ? .template : .original)
            .interpolation(.none)
            .frame(width: 18, height: 18)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Codex quota")
            .accessibilityValue(accessibilityValue)
            .help(accessibilityValue)
    }

    private var statusImage: NSImage {
        MenuBarQuotaIconRenderer.image(
            windows: windows,
            style: style,
            alertRemainingPercent: alertRemainingPercent
        )
    }

    private var primaryWindow: UsageQuotaWindow? {
        windows
            .filter { $0.windowMinutes != 10_080 }
            .min { $0.windowMinutes < $1.windowMinutes }
    }

    private var weeklyWindow: UsageQuotaWindow? {
        windows.first(where: { $0.windowMinutes == 10_080 })
    }

    private var accessibilityValue: String {
        let displayedWindows = [primaryWindow, weeklyWindow].compactMap { $0 }
        guard !displayedWindows.isEmpty else { return "Quota unavailable" }
        let quotaDescription = displayedWindows.map { window in
            "\(window.displayName): \(window.remainingPercent.formatted(.number.precision(.fractionLength(0))))% remaining"
        }.joined(separator: ", ")
        guard let alertRemainingPercent else { return quotaDescription }
        let threshold = alertRemainingPercent.formatted(.number.precision(.fractionLength(0)))
        let isReached = displayedWindows.contains { $0.remainingPercent <= alertRemainingPercent }
        return "\(quotaDescription). Alert marker at \(threshold)% remaining\(isReached ? ", reached" : "")"
    }
}

private struct MenuBarDashboardView: View {
    @EnvironmentObject private var store: DashboardStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("showQuotaAlertMarker") private var showQuotaAlertMarker = false
    @AppStorage("quotaAlertUsedPercent") private var quotaAlertRemainingPercent = 80.0
    @AppStorage("menuBarUsageTrendMetric") private var usageTrendMetricRawValue = MenuUsageTrendMetric.cost.rawValue

    private var usageTrendMetric: Binding<MenuUsageTrendMetric> {
        Binding(
            get: { MenuUsageTrendMetric(rawValue: usageTrendMetricRawValue) ?? .cost },
            set: { usageTrendMetricRawValue = $0.rawValue }
        )
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)

            VStack(spacing: 0) {
                header

                if let windows = store.subscription?.windows, !windows.isEmpty {
                    sectionDivider
                    VStack(spacing: 0) {
                        ForEach(windows) { quotaRow($0) }
                    }
                }

                if let bankedResets = store.bankedResets, bankedResets.availableCount > 0 {
                    sectionDivider
                    bankedResetSection(bankedResets)
                }

                sectionDivider
                usageTrend

                sectionDivider
                HStack(spacing: 0) {
                    MenuBarActionButton(
                        title: "Open Dashboard",
                        systemImage: "rectangle.grid.2x2.fill",
                        tint: .teal
                    ) {
                        AppActivationPolicy.dismissMenuBarExtra()
                        store.activateDashboard()
                        openWindow(id: "dashboard")
                        AppActivationPolicy.bringWindowToFront(identifier: .dashboard)
                    }
                    toolbarDivider
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
                    toolbarDivider
                    MenuBarActionButton(
                        title: "Quit Codex Dashboard",
                        systemImage: "power",
                        tint: .red
                    ) {
                        NSApp.terminate(nil)
                    }
                    .keyboardShortcut("q", modifiers: .command)
                }
                .frame(height: 44)
                .background(Color.primary.opacity(0.025))
            }
        }
        .frame(width: 390)
        .onAppear { store.loadMenuBarPopover() }
        .onDisappear { store.releaseMenuBarMemory() }
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(.separator.opacity(0.5))
            .frame(height: 0.5)
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(.separator.opacity(0.45))
            .frame(width: 0.5, height: 24)
    }

    private var header: some View {
        HStack(spacing: 10) {
            MenuBarAppIcon(statusColor: headerQuotaColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.account?.email ?? "Codex Dashboard")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(planLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isBusy { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var headerQuotaColor: Color? {
        store.subscription?.windows
            .map(\.remainingPercent)
            .min()
            .map { quotaColor(for: $0) }
    }

    private var planLabel: String {
        if let plan = store.subscription?.displayPlan { return "ChatGPT \(plan)" }
        if let plan = store.account?.planType { return "ChatGPT \(CodexPlanDisplay.name(for: plan))" }
        return "Plan not reported"
    }

    private func bankedResetSection(_ snapshot: BankedResetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Label("Banked resets", systemImage: "arrow.counterclockwise.circle.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(snapshot.availableCount.formatted())
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.teal)
            }

            if let credits = snapshot.credits, !credits.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(credits.prefix(3)) { credit in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(credit.title ?? "Codex reset")
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if let expiresAt = credit.expiresAt {
                                Text("Expires \(expiresAt, style: .relative)")
                            } else {
                                Text("No expiry reported")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Available to use when needed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let credits = snapshot.credits,
               snapshot.availableCount > credits.count {
                Text("OpenAI reports \(snapshot.availableCount - credits.count) more reset\(snapshot.availableCount - credits.count == 1 ? "" : "s") available.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func quotaRow(_ window: UsageQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(window.remainingPercent.formatted(.number.precision(.fractionLength(0))))%")
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(quotaColor(for: window.remainingPercent))
                    Text("remaining")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            QuotaRemainingBar(
                remainingPercent: window.remainingPercent,
                alertRemainingPercent: $quotaAlertRemainingPercent,
                showsAlertMarker: showQuotaAlertMarker
            )
            HStack {
                Text("Resets \(window.resetsAt, style: .relative)")
                Spacer()
                if showQuotaAlertMarker {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.red)
                            .frame(width: 5, height: 5)
                        Text("Attention at \(quotaAlertRemainingPercent.formatted(.number.precision(.fractionLength(0))))%")
                            .monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Button {
                        showQuotaAlertMarker = true
                    } label: {
                        Text("Set attention marker")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }

    private var usageTrend: some View {
        let calendar = store.analyticsCalendar
        let now = Date.now
        let todayInterval = calendar.dateInterval(of: .day, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 86_400)
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now) ?? todayInterval
        let monthInterval = calendar.dateInterval(of: .month, for: now) ?? todayInterval
        let today = store.menuBarAggregate(in: todayInterval)
        let week = store.menuBarAggregate(in: weekInterval)
        let month = store.menuBarAggregate(in: monthInterval)

        return MenuUsageTrendView(
            metric: usageTrendMetric,
            days: monthUsageDays(in: monthInterval, calendar: calendar),
            currentWeekDays: currentWeekDays(
                weekInterval: weekInterval,
                monthInterval: monthInterval,
                calendar: calendar
            ),
            todayDay: calendar.component(.day, from: now),
            today: MenuUsageSummary(aggregate: today),
            week: MenuUsageSummary(aggregate: week),
            month: MenuUsageSummary(aggregate: month)
        )
    }

    private func monthUsageDays(in interval: DateInterval, calendar: Calendar) -> [MenuUsageDay] {
        let dailyByStart = Dictionary(store.menuBarDaily.map { (calendar.startOfDay(for: $0.start), $0) }) { _, latest in latest }
        let dayCount = calendar.range(of: .day, in: .month, for: interval.start)?.count ?? 1

        var days: [MenuUsageDay] = []
        days.reserveCapacity(dayCount)
        for offset in 0..<dayCount {
            if let date = calendar.date(byAdding: .day, value: offset, to: interval.start) {
                let start = calendar.startOfDay(for: date)
                days.append(MenuUsageDay(date: start, period: dailyByStart[start]))
            }
        }
        return days
    }

    private func currentWeekDays(
        weekInterval: DateInterval,
        monthInterval: DateInterval,
        calendar: Calendar
    ) -> ClosedRange<Int> {
        let clippedStart = max(weekInterval.start, monthInterval.start)
        let clippedEnd = min(weekInterval.end, monthInterval.end)
        let finalDay = calendar.date(byAdding: .day, value: -1, to: clippedEnd) ?? clippedStart
        return calendar.component(.day, from: clippedStart)...calendar.component(.day, from: finalDay)
    }
}

private enum MenuUsageTrendMetric: String, CaseIterable, Identifiable {
    case cost = "Cost"
    case tokens = "Tokens"

    var id: String { rawValue }
}

private struct MenuUsageDay: Identifiable {
    let date: Date
    let period: PeriodMetric?

    var id: Date { date }
    var day: Int { Calendar.current.component(.day, from: date) }
}

private struct MenuUsageSummary {
    let cost: Decimal
    let tokens: Int64
    let tools: Int
    let skills: Int

    init(aggregate: MenuBarUsageAggregate) {
        cost = aggregate.estimatedCost
        tokens = aggregate.usage.total
        tools = aggregate.toolCalls
        skills = aggregate.skillCalls
    }
}

private struct MenuUsageTrendView: View {
    @Binding var metric: MenuUsageTrendMetric
    let days: [MenuUsageDay]
    let currentWeekDays: ClosedRange<Int>
    let todayDay: Int
    let today: MenuUsageSummary
    let week: MenuUsageSummary
    let month: MenuUsageSummary

    // MenuBarExtra measures its content before the popover has a stable window
    // width. Keep this view's layout finite during that first measurement pass.
    private let contentWidth: CGFloat = 342
    private let barSpacing: CGFloat = 3
    private let comparisonTrailingWidth: CGFloat = 85
    private let comparisonBarWidth: CGFloat = 47

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(.teal)
                    Text(insightLabel)
                        .foregroundStyle(.secondary)
                }
                .font(.caption2.weight(.medium))
                .accessibilityElement(children: .combine)

                Spacer(minLength: 8)

                Picker("Usage chart metric", selection: $metric) {
                    ForEach(MenuUsageTrendMetric.allCases) { metric in
                        Text(metric.rawValue.uppercased()).tag(metric)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 132)
            }

            VStack(spacing: 5) {
                monthBars
                monthAxis
                weekSpanMarker
            }

            Divider().opacity(0.55)

            VStack(spacing: 8) {
                comparisonHeader
                comparisonRow("TODAY", summary: today, tint: .cyan)
                comparisonRow("WEEK", summary: week, tint: .teal)
                comparisonRow("MONTH", summary: month, tint: .secondary)
            }
        }
        .frame(width: contentWidth)
        .padding(14)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator.opacity(0.38), lineWidth: 0.5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private var monthBars: some View {
        let barWidth = resolvedBarWidth
        return HStack(alignment: .bottom, spacing: barSpacing) {
            ForEach(days) { day in
                let height = barHeight(for: day)
                let isToday = day.day == todayDay
                let isFuture = day.day > todayDay
                let isThisWeek = currentWeekDays.contains(day.day)

                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(isFuture ? Color.clear : barColor(isToday: isToday, isThisWeek: isThisWeek))
                    .overlay {
                        if isFuture {
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .stroke(isThisWeek ? Color.teal.opacity(0.52) : Color.secondary.opacity(0.28), lineWidth: 0.7)
                        }
                    }
                    .frame(width: barWidth, height: height)
                    .overlay(alignment: .top) {
                        if isToday {
                            Circle()
                                .fill(.cyan)
                                .frame(width: 6, height: 6)
                                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1))
                                .shadow(color: .cyan.opacity(0.65), radius: 4)
                                .offset(y: -5)
                        }
                    }
                    .accessibilityLabel(day.date.formatted(date: .long, time: .omitted))
                    .accessibilityValue(dayValueLabel(day))
            }
        }
        .frame(width: contentWidth, height: 78, alignment: .bottom)
    }

    private var monthAxis: some View {
        HStack(spacing: 0) {
            Text(monthAnchorLabel(day: 1))
            Spacer()
            Text(monthAnchorLabel(day: 8))
            Spacer()
            Text(monthAnchorLabel(day: 15))
            Spacer()
            Text("TODAY \(todayDay)").foregroundStyle(.cyan)
            Spacer()
            Text(monthAnchorLabel(day: days.count))
        }
        .font(.system(size: 8, weight: .medium).monospacedDigit())
        .foregroundStyle(.tertiary)
    }

    private var weekSpanMarker: some View {
        let count = max(1, days.count)
        let startIndex = max(0, currentWeekDays.lowerBound - 1)
        let endIndex = min(count - 1, currentWeekDays.upperBound - 1)
        let startX = CGFloat(startIndex) * (resolvedBarWidth + barSpacing)
        let spanWidth = CGFloat(endIndex - startIndex + 1) * resolvedBarWidth
            + CGFloat(max(0, endIndex - startIndex)) * barSpacing

        return HStack(spacing: 0) {
            Color.clear.frame(width: startX)
            CompactWeekMarker()
                .frame(width: spanWidth, height: 14)
            Spacer(minLength: 0)
        }
        .frame(width: contentWidth, height: 14)
        .accessibilityHidden(true)
    }

    private var comparisonHeader: some View {
        HStack(spacing: 5) {
            Text("").frame(width: 56)
            Text("COST").frame(width: 60, alignment: .trailing)
            Text("TOKENS").frame(width: 46, alignment: .trailing)
            Text("TOOLS").frame(width: 34, alignment: .trailing)
            Text("SKILLS").frame(width: 36, alignment: .trailing)
            Text("MONTH %").frame(width: comparisonTrailingWidth, alignment: .trailing)
        }
        .font(.system(size: 7.5, weight: .bold))
        .tracking(0.25)
        .foregroundStyle(.tertiary)
    }

    private func comparisonRow(_ title: String, summary: MenuUsageSummary, tint: Color) -> some View {
        let share = monthShare(for: summary)
        return HStack(spacing: 5) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(title == "MONTH" ? .secondary : tint)
            .frame(width: 56, alignment: .leading)

            Text(MetricFormatters.preciseCurrency(summary.cost))
                .frame(width: 60, alignment: .trailing)
            Text(MetricFormatters.compactNumber(summary.tokens))
                .frame(width: 46, alignment: .trailing)
            Text(summary.tools.formatted(.number.notation(.compactName)))
                .frame(width: 34, alignment: .trailing)
            Text(summary.skills.formatted(.number.notation(.compactName)))
                .frame(width: 36, alignment: .trailing)

            HStack(spacing: 4) {
                Text(share.formatted(.percent.precision(.fractionLength(0))))
                    .frame(width: 34, alignment: .trailing)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(tint.opacity(0.85))
                        .frame(width: comparisonBarWidth * min(1, max(0, share)))
                }
                .frame(width: comparisonBarWidth, height: 4)
            }
            .frame(width: comparisonTrailingWidth)
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(MetricFormatters.preciseCurrency(summary.cost)), \(MetricFormatters.compactNumber(summary.tokens)) tokens, \(summary.tools) tools, \(summary.skills) skills, \(share.formatted(.percent.precision(.fractionLength(0)))) of the month")
    }

    private func barValue(_ day: MenuUsageDay) -> Double {
        guard let period = day.period else { return 0 }
        return switch metric {
        case .cost: NSDecimalNumber(decimal: period.estimatedCost).doubleValue
        case .tokens: Double(period.usage.total)
        }
    }

    private var resolvedBarWidth: CGFloat {
        let count = CGFloat(max(1, days.count))
        return max(1, (contentWidth - barSpacing * (count - 1)) / count)
    }

    private func summaryValue(_ summary: MenuUsageSummary) -> Double {
        return switch metric {
        case .cost: NSDecimalNumber(decimal: summary.cost).doubleValue
        case .tokens: Double(summary.tokens)
        }
    }

    private func barHeight(for day: MenuUsageDay) -> CGFloat {
        guard day.day <= todayDay else { return 5 }
        let maximum = max(1, days.lazy.filter { $0.day <= todayDay }.map(barValue).max() ?? 0)
        let fraction = min(1, max(0, barValue(day) / maximum))
        // Daily usage is naturally spiky. A square-root scale keeps outliers
        // dominant without flattening the rest of the month's trend into noise.
        return max(3, 68 * sqrt(fraction))
    }

    private func barColor(isToday: Bool, isThisWeek: Bool) -> Color {
        if isToday { return .cyan }
        if isThisWeek { return .teal.opacity(0.82) }
        return .secondary.opacity(0.36)
    }

    private func monthShare(for summary: MenuUsageSummary) -> Double {
        let denominator = summaryValue(month)
        guard denominator > 0 else { return 0 }
        return min(1, max(0, summaryValue(summary) / denominator))
    }

    private var insightLabel: String {
        let completedDays = max(1, min(todayDay, days.count))
        let average = summaryValue(month) / Double(completedDays)
        guard average > 0 else { return "No usage recorded this month" }
        let ratio = summaryValue(today) / average
        return "Today is \(ratio.formatted(.number.precision(.fractionLength(1))))× daily avg"
    }

    private func monthAnchorLabel(day: Int) -> String {
        guard let firstDate = days.first?.date else { return "—" }
        let month = firstDate.formatted(.dateTime.month(.abbreviated)).uppercased()
        return "\(month) \(day)"
    }

    private func dayValueLabel(_ day: MenuUsageDay) -> String {
        switch metric {
        case .cost: return MetricFormatters.preciseCurrency(day.period?.estimatedCost ?? 0)
        case .tokens: return "\(MetricFormatters.compactNumber(day.period?.usage.total ?? 0)) tokens"
        }
    }
}

private struct CompactWeekMarker: View {
    var body: some View {
        HStack(spacing: 4) {
            Rectangle().frame(height: 0.5)
            Text("THIS WEEK")
                .font(.system(size: 7, weight: .bold))
                .tracking(0.35)
                .fixedSize()
            Rectangle().frame(height: 0.5)
        }
        .foregroundStyle(.cyan)
        .overlay {
            HStack {
                Rectangle().frame(width: 0.5, height: 7)
                Spacer(minLength: 0)
                Rectangle().frame(width: 0.5, height: 7)
            }
            .foregroundStyle(.cyan)
        }
    }
}

private struct QuotaRemainingBar: View {
    let remainingPercent: Double
    @Binding var alertRemainingPercent: Double
    let showsAlertMarker: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDraggingAlert = false

    private var fraction: Double {
        min(1, max(0, remainingPercent / 100))
    }

    private var color: Color { quotaColor(for: remainingPercent) }

    private var alertRemainingFraction: Double {
        min(1, max(0, alertRemainingPercent / 100))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                    .frame(height: 6)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.72), color],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * fraction)
                    .frame(height: 6)
                    .shadow(color: color.opacity(0.2), radius: 3)

                if showsAlertMarker {
                    alertMarker
                        .position(
                            x: markerX(in: proxy.size.width),
                            y: proxy.size.height / 2
                        )
                }
            }
            .contentShape(Rectangle())
            .gesture(alertDragGesture(width: proxy.size.width))
        }
        .frame(height: 14)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: fraction)
        .animation(
            reduceMotion || isDraggingAlert ? nil : .snappy(duration: 0.2),
            value: alertRemainingFraction
        )
        .onHover { isHovering in
            guard showsAlertMarker else { return }
            if isHovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Quota remaining")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            guard showsAlertMarker else { return }
            switch direction {
            case .increment:
                alertRemainingPercent = min(100, alertRemainingPercent + 1)
            case .decrement:
                alertRemainingPercent = max(10, alertRemainingPercent - 1)
            @unknown default:
                break
            }
        }
    }

    private var alertMarker: some View {
        ZStack {
            Capsule()
                .fill(.red)
                .frame(width: 2, height: 14)
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .overlay {
                    Circle().stroke(.white.opacity(0.9), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
        }
        .frame(width: 12, height: 14)
    }

    private func markerX(in width: CGFloat) -> CGFloat {
        min(max(4, width * alertRemainingFraction), max(4, width - 4))
    }

    private func alertDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard showsAlertMarker, width > 0 else { return }
                isDraggingAlert = true
                let remainingFraction = min(1, max(0, value.location.x / width))
                alertRemainingPercent = min(100, max(10, (remainingFraction * 100).rounded()))
            }
            .onEnded { _ in
                isDraggingAlert = false
            }
    }

    private var accessibilityValue: String {
        let remaining = remainingPercent.formatted(.percent.scale(1).precision(.fractionLength(0)))
        guard showsAlertMarker else { return remaining }
        let alert = alertRemainingPercent.formatted(.number.precision(.fractionLength(0)))
        return "\(remaining) remaining, alert marker at \(alert)% remaining"
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

    @MainActor
    private static let cachedAppIcon: NSImage = {
        let original = NSApp.applicationIconImage ?? NSImage()
        let size = NSSize(width: 32, height: 32)
        let image = NSImage(size: size)
        image.lockFocus()
        original.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1.0)
        image.unlockFocus()
        return image
    }()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: Self.cachedAppIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 2.5, y: 1)

            if let statusColor {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .overlay {
                        Circle().stroke(Color.black.opacity(0.22), lineWidth: 0.5)
                    }
                    .padding(1.5)
                    .background(.ultraThickMaterial, in: Circle())
                    .offset(x: 1, y: 1)
            }
        }
        .frame(width: 32, height: 32)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(isHovering ? tint.opacity(0.11) : Color.clear)
                .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @AppStorage("showQuotaAlertMarker") private var showQuotaAlertMarker = false
    @AppStorage("quotaAlertUsedPercent") private var quotaAlertRemainingPercent = 80.0
    @AppStorage("weekStartsMonday") private var weekStartsMonday = true
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
                                MenuBarQuotaIcon(
                                    windows: quotaIconPreviewWindows,
                                    style: style,
                                    alertRemainingPercent: showQuotaAlertMarker ? quotaAlertRemainingPercent : nil
                                )
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
                Toggle("Show quota alert marker", isOn: $showQuotaAlertMarker)
                    .disabled(!showMenuBarIcon)
                if showQuotaAlertMarker {
                    LabeledContent("Attention at") {
                        HStack(spacing: 10) {
                            Slider(value: $quotaAlertRemainingPercent, in: 10...100, step: 5)
                            Text("\(quotaAlertRemainingPercent.formatted(.number.precision(.fractionLength(0))))% remaining")
                                .monospacedDigit()
                                .frame(width: 104, alignment: .trailing)
                        }
                        .frame(width: 260)
                    }
                    .disabled(!showMenuBarIcon)
                }
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
                LabeledContent("First day of week") {
                    Picker("First day of week", selection: $weekStartsMonday) {
                        Text("Monday").tag(true)
                        Text("Sunday").tag(false)
                    }
                    .onChange(of: weekStartsMonday) { _, _ in
                        store.updateWeekStartsMonday(weekStartsMonday)
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

            Section("Maintenance") {
                LabeledContent("History index") {
                    Button {
                        store.rebuildHistoryIndex()
                    } label: {
                        if store.isRebuildingHistory {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Rebuild")
                        }
                    }
                    .disabled(store.isBusy)
                }
                Text("Rebuilds the stored token, cost, runtime, and model breakdowns from all saved sessions. This may take a while for large histories.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                LabeledContent("Software Update") {
                    Button("Check for Updates…") {
                        AppUpdater.shared.checkForUpdates()
                    }
                }
                LabeledContent("Current Version") {
                    Text(appVersionDescription)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(4)
    }

    private var appVersionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(version) (\(build))"
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

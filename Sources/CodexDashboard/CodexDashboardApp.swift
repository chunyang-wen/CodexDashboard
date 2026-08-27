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
private final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
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
        .defaultSize(width: 520, height: 420)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink()
            }
        }
    }
}

@MainActor
enum MenuBarQuotaIconRenderer {
    private static let alertLineWidth: CGFloat = 1.4

    struct AlertMarkers: Hashable {
        static let none = AlertMarkers(primary: nil, secondary: nil)

        let primary: Double?
        let secondary: Double?

        var isEmpty: Bool { primary == nil && secondary == nil }
    }

    struct Key: Hashable {
        let windows: [UsageQuotaWindow]
        let style: MenuBarQuotaIconStyle
        let alertMarkers: AlertMarkers
    }

    private static var cachedKey: Key?
    private static var cachedImage: NSImage?

    static func image(
        windows: [UsageQuotaWindow],
        style: MenuBarQuotaIconStyle,
        alertMarkers: AlertMarkers = .none
    ) -> NSImage {
        let key = Key(windows: windows, style: style, alertMarkers: alertMarkers)
        if let cachedImage, cachedKey == key {
            return cachedImage
        }
        let rendered = render(windows: windows, style: style, alertMarkers: alertMarkers)
        cachedKey = key
        cachedImage = rendered
        return rendered
    }

    private static func render(
        windows: [UsageQuotaWindow],
        style: MenuBarQuotaIconStyle,
        alertMarkers: AlertMarkers
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

        let orderedWindows = windows.sorted { $0.windowMinutes > $1.windowMinutes }
        let primaryWindow = orderedWindows.first
        let secondaryWindow = orderedWindows.dropFirst().first
        let iconInk: NSColor = alertMarkers.isEmpty ? .black : .labelColor

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: representation) {
            NSGraphicsContext.current = context
            context.cgContext.setShouldAntialias(true)
            switch style {
            case .rings: drawRings(primaryWindow: primaryWindow, secondaryWindow: secondaryWindow, iconInk: iconInk)
            case .droplet: drawDroplet(primaryWindow: primaryWindow, secondaryWindow: secondaryWindow, iconInk: iconInk)
            case .capsules: drawCapsules(primaryWindow: primaryWindow, secondaryWindow: secondaryWindow, iconInk: iconInk)
            case .twoRows:
                drawTwoRows(
                    primaryWindow: primaryWindow,
                    secondaryWindow: secondaryWindow,
                    alertMarkers: alertMarkers,
                    iconInk: iconInk
                )
            }
            drawAlertMarkers(
                style: style,
                primaryWindow: primaryWindow,
                secondaryWindow: secondaryWindow,
                alertMarkers: alertMarkers
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        image.isTemplate = alertMarkers.isEmpty
        return image
    }

    private static func drawRings(primaryWindow: UsageQuotaWindow?, secondaryWindow: UsageQuotaWindow?, iconInk: NSColor) {
        drawRing(radius: 6.8, lineWidth: 2.4, window: primaryWindow, iconInk: iconInk)
        drawRing(radius: 3.2, lineWidth: 1.8, window: secondaryWindow, iconInk: iconInk)
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

    private static func drawDroplet(primaryWindow: UsageQuotaWindow?, secondaryWindow: UsageQuotaWindow?, iconInk: NSColor) {
        let left = dropletChamber(left: true)
        let right = dropletChamber(left: false)
        drawLiquid(in: left, bounds: NSRect(x: 1.7, y: 2, width: 6.65, height: 14), window: primaryWindow, iconInk: iconInk)
        drawLiquid(in: right, bounds: NSRect(x: 9.65, y: 2, width: 6.65, height: 14), window: secondaryWindow, iconInk: iconInk)
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

    private static func drawCapsules(primaryWindow: UsageQuotaWindow?, secondaryWindow: UsageQuotaWindow?, iconInk: NSColor) {
        drawCapsule(in: NSRect(x: 1.5, y: 9, width: 15, height: 6), window: primaryWindow, iconInk: iconInk)
        drawCapsule(in: NSRect(x: 1.5, y: 3, width: 15, height: 4), window: secondaryWindow, iconInk: iconInk)
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

    private static func drawTwoRows(
        primaryWindow: UsageQuotaWindow?,
        secondaryWindow: UsageQuotaWindow?,
        alertMarkers: AlertMarkers,
        iconInk: NSColor
    ) {
        if let primaryWindow, let secondaryWindow {
            drawTwoRowsValue(for: primaryWindow, centerY: 13.5, alertRemainingPercent: alertMarkers.primary, iconInk: iconInk)
            drawTwoRowsValue(for: secondaryWindow, centerY: 4.5, alertRemainingPercent: alertMarkers.secondary, iconInk: iconInk)
        } else if let window = primaryWindow ?? secondaryWindow {
            drawTwoRowsValue(
                for: window,
                centerY: 9,
                alertRemainingPercent: primaryWindow == nil ? alertMarkers.secondary : alertMarkers.primary,
                iconInk: iconInk
            )
        } else {
            drawTwoRowsText("N/A", centerY: 9, iconInk: iconInk.withAlphaComponent(0.45))
        }
    }

    private static func drawTwoRowsValue(
        for window: UsageQuotaWindow,
        centerY: CGFloat,
        alertRemainingPercent: Double?,
        iconInk: NSColor
    ) {
        drawTwoRowsText(
            "\(Int(window.remainingPercent.rounded()))%",
            centerY: centerY,
            iconInk: alertRemainingPercent.map { window.remainingPercent <= $0 } == true ? .systemRed : iconInk
        )
    }

    private static func drawTwoRowsText(_ value: String, centerY: CGFloat, iconInk: NSColor) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: value.count > 3 ? 5.5 : 7, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: iconInk
        ]
        let size = (value as NSString).size(withAttributes: attributes)
        let rect = NSRect(
            x: 9 - size.width / 2,
            y: centerY - size.height / 2,
            width: size.width,
            height: size.height
        )
        (value as NSString).draw(in: rect, withAttributes: attributes)
    }

    private static func drawAlertMarkers(
        style: MenuBarQuotaIconStyle,
        primaryWindow: UsageQuotaWindow?,
        secondaryWindow: UsageQuotaWindow?,
        alertMarkers: AlertMarkers
    ) {
        switch style {
        case .rings:
            if let alert = alertMarkers.primary, primaryWindow != nil {
                drawRingAlertLine(radius: 6.8, ringWidth: 2.4, remainingPercent: alert)
            }
            if let alert = alertMarkers.secondary, secondaryWindow != nil {
                drawRingAlertLine(radius: 3.2, ringWidth: 1.8, remainingPercent: alert)
            }
        case .droplet:
            if let alert = alertMarkers.primary, primaryWindow != nil {
                drawAlertBar(y: alertY(alert), from: 1.5, to: 8.5, clippedTo: dropletChamber(left: true))
            }
            if let alert = alertMarkers.secondary, secondaryWindow != nil {
                drawAlertBar(y: alertY(alert), from: 9.5, to: 16.5, clippedTo: dropletChamber(left: false))
            }
        case .capsules:
            if let alert = alertMarkers.primary, primaryWindow != nil {
                drawCapsuleAlertLine(remainingPercent: alert, y: 12, height: 5)
            }
            if let alert = alertMarkers.secondary, secondaryWindow != nil {
                drawCapsuleAlertLine(remainingPercent: alert, y: 5, height: 3)
            }
        case .twoRows:
            break
        }
    }

    private static func ringMarkerPoint(radius: CGFloat, remainingPercent: Double) -> NSPoint {
        let fraction = CGFloat(min(100, max(0, remainingPercent)) / 100)
        let angle = CGFloat.pi / 2 - 2 * .pi * fraction
        return NSPoint(x: 9 + radius * cos(angle), y: 9 + radius * sin(angle))
    }

    private static func alertY(_ remainingPercent: Double) -> CGFloat {
        2 + 14 * CGFloat(min(100, max(0, remainingPercent)) / 100)
    }

    private static func capsuleMarkerPoint(remainingPercent: Double, y: CGFloat) -> NSPoint {
        let fraction = CGFloat(min(100, max(0, remainingPercent)) / 100)
        return NSPoint(x: 1.5 + 15 * fraction, y: y)
    }

    private static func drawRingAlertLine(radius: CGFloat, ringWidth: CGFloat, remainingPercent: Double) {
        let fraction = CGFloat(min(100, max(0, remainingPercent)) / 100)
        let angle = CGFloat.pi / 2 - 2 * .pi * fraction
        let center = ringMarkerPoint(radius: radius, remainingPercent: remainingPercent)
        let radial = NSPoint(x: cos(angle), y: sin(angle))
        let halfLength = ringWidth / 2
        drawAlertLine(
            from: NSPoint(x: center.x - radial.x * halfLength, y: center.y - radial.y * halfLength),
            to: NSPoint(x: center.x + radial.x * halfLength, y: center.y + radial.y * halfLength),
            lineCapStyle: .butt
        )
    }

    private static func drawCapsuleAlertLine(remainingPercent: Double, y: CGFloat, height: CGFloat) {
        let point = capsuleMarkerPoint(remainingPercent: remainingPercent, y: y)
        drawAlertLine(
            from: NSPoint(x: point.x, y: point.y - height / 2),
            to: NSPoint(x: point.x, y: point.y + height / 2)
        )
    }

    private static func drawAlertLine(
        from start: NSPoint,
        to end: NSPoint,
        lineCapStyle: NSBezierPath.LineCapStyle = .round
    ) {
        let line = NSBezierPath()
        line.move(to: start)
        line.line(to: end)
        line.lineWidth = alertLineWidth
        line.lineCapStyle = lineCapStyle
        NSColor.systemRed.setStroke()
        line.stroke()
    }

    private static func drawAlertBar(y: CGFloat, from startX: CGFloat, to endX: CGFloat, clippedTo clip: NSBezierPath) {
        NSGraphicsContext.current?.cgContext.saveGState()
        clip.addClip()
        let bar = NSBezierPath()
        bar.move(to: NSPoint(x: startX, y: y))
        bar.line(to: NSPoint(x: endX, y: y))
        bar.lineWidth = alertLineWidth
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
    var alertMarkers: MenuBarQuotaIconRenderer.AlertMarkers = .none

    var body: some View {
        Image(nsImage: statusImage)
            .renderingMode(alertMarkers.isEmpty ? .template : .original)
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
            alertMarkers: alertMarkers
        )
    }

    private var displayedWindows: [UsageQuotaWindow] {
        Array(windows.sorted { $0.windowMinutes > $1.windowMinutes }.prefix(2))
    }

    private var accessibilityValue: String {
        guard !displayedWindows.isEmpty else { return "Quota unavailable" }
        let quotaDescription = displayedWindows.map { window in
            "\(window.displayName): \(window.remainingPercent.formatted(.number.precision(.fractionLength(0))))% remaining"
        }.joined(separator: ", ")
        let markers = [alertMarkers.primary, alertMarkers.secondary].compactMap { $0 }
        guard !markers.isEmpty else { return quotaDescription }
        let thresholds = markers.map { $0.formatted(.number.precision(.fractionLength(0))) }
        return "\(quotaDescription). Attention markers at \(thresholds.joined(separator: ", "))% remaining"
    }
}

private enum SubscriptionProviderValidationState: Equatable {
    case idle
    case validating
    case valid(String)
    case invalid(String)
}

private struct DashboardSettingsView: View {
    @EnvironmentObject private var store: MenuBarStore
    @AppStorage(DashboardPreferences.showMenuBarIconKey, store: DashboardPreferences.sharedDefaults()) private var showMenuBarIcon = true
    @AppStorage(DashboardPreferences.menuBarQuotaIconStyleKey, store: DashboardPreferences.sharedDefaults()) private var menuBarQuotaIconStyle = MenuBarQuotaIconStyle.rings.rawValue
    @AppStorage(DashboardPreferences.weekStartsMondayKey, store: DashboardPreferences.sharedDefaults()) private var weekStartsMonday = true
    @AppStorage(DashboardPreferences.subscriptionProviderKey, store: DashboardPreferences.sharedDefaults()) private var subscriptionProviderRaw = DashboardSubscriptionProvider.default.rawValue
    @State private var selectedSubscriptionProviderRaw = DashboardSubscriptionProvider.default.rawValue
    @State private var cliProxyAPIEndpoint = "http://127.0.0.1:8317"
    @State private var cliProxyAPIManagementKey = ""
    @State private var cliProxyAPIValidationState: SubscriptionProviderValidationState = .idle
    @State private var sub2APIEndpoint = "http://127.0.0.1:8080"
    @State private var sub2APIAdminEmail = ""
    @State private var sub2APIAdminPassword = ""
    @State private var sub2APIAdminToken = ""
    @State private var sub2APIAccounts: [Sub2APIAdminAccount] = []
    @State private var sub2APIAccountID = ""
    @State private var sub2APIValidationState: SubscriptionProviderValidationState = .idle
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    private let settingsControlWidth: CGFloat = 190

    var body: some View {
        Form {
            Section("Subscription source") {
                Picker("Provider", selection: $selectedSubscriptionProviderRaw) {
                    ForEach(DashboardSubscriptionProvider.allCases) { provider in
                        Text(provider.label).tag(provider.rawValue)
                    }
                }
                .onChange(of: selectedSubscriptionProviderRaw) { _, rawValue in
                    selectSubscriptionProvider(rawValue)
                }

                if selectedSubscriptionProvider == .cliProxyAPI {
                    Text("CLIProxyAPI keeps the OAuth credentials. CodexDashboard selects the first active Codex credential returned by its management API.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Endpoint", text: $cliProxyAPIEndpoint)
                        .textContentType(.URL)

                    SecureField("Management key", text: $cliProxyAPIManagementKey)

                    HStack {
                        Button {
                            activateCLIProxyAPIConfiguration()
                        } label: {
                            Text(cliProxyAPIValidationState == .validating ? "Activating…" : "Activate CLIProxyAPI")
                        }
                        .disabled(cliProxyAPIValidationState == .validating)

                        switch cliProxyAPIValidationState {
                        case .idle:
                            EmptyView()
                        case .validating:
                            ProgressView()
                                .controlSize(.small)
                        case .valid(let message):
                            Label(message, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        case .invalid(let message):
                            Label(message, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                    Text("The management key is stored in macOS Keychain, not in preferences or logs. It is not your OAuth token.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if selectedSubscriptionProvider == .sub2API {
                    Text("Sub2API routes user API keys through backend-managed subscription accounts. CodexDashboard reads the selected upstream account's quota through the admin API.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Endpoint", text: $sub2APIEndpoint)
                        .textContentType(.URL)

                    TextField("Admin email", text: $sub2APIAdminEmail)
                        .textContentType(.username)

                    SecureField("Admin password", text: $sub2APIAdminPassword)
                        .textContentType(.password)

                    if sub2APIAccounts.isEmpty {
                        Text(hasSub2APIActivationCredentials
                            ? "Upstream accounts are unavailable. The saved account remains selected; activate to retry."
                            : "Sign in to load OpenAI/Codex upstream accounts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Upstream account", selection: $sub2APIAccountID) {
                            ForEach(sub2APIAccounts) { account in
                                Text("\(account.name) (\(account.id))")
                                    .tag(String(account.id))
                            }
                        }
                    }

                    HStack {
                        Button {
                            signInToSub2API()
                        } label: {
                            Text(sub2APIValidationState == .validating ? "Signing in…" : "Sign in")
                        }
                        .disabled(sub2APIValidationState == .validating)

                        Button {
                            activateSub2APIConfiguration()
                        } label: {
                            Text(sub2APIValidationState == .validating ? "Activating…" : "Activate sub2api")
                        }
                        .disabled(sub2APIValidationState == .validating || !hasSub2APIActivationCredentials)

                        switch sub2APIValidationState {
                        case .idle:
                            EmptyView()
                        case .validating:
                            ProgressView()
                                .controlSize(.small)
                        case .valid(let message):
                            Label(message, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        case .invalid(let message):
                            Label(message, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                    Text("Sign-in uses the password only for authentication. The returned admin access token is stored in macOS Keychain; the endpoint and selected account are stored in preferences.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Use the local Codex data folder for subscription and quota information.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

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
                HStack {
                    Text("Quota icon")
                    Spacer()
                    Picker("Quota icon", selection: $menuBarQuotaIconStyle) {
                        ForEach(MenuBarQuotaIconStyle.allCases) { style in
                            HStack(spacing: 8) {
                                MenuBarQuotaIcon(
                                    windows: quotaIconPreviewWindows,
                                    style: style
                                )
                                    .accessibilityHidden(true)
                                Text(style.label)
                            }
                            .tag(style.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: settingsControlWidth, alignment: .trailing)
                }
                .disabled(!showMenuBarIcon)
                .frame(maxWidth: .infinity)
                HStack {
                    Text("Refresh metrics")
                    Spacer()
                    Picker("Refresh metrics", selection: refreshBinding) {
                        Text("Manually").tag(TimeInterval(0))
                        Text("Every 15 seconds").tag(TimeInterval(15))
                        Text("Every minute").tag(TimeInterval(60))
                        Text("Every 5 minutes").tag(TimeInterval(300))
                    }
                    .labelsHidden()
                    .frame(width: settingsControlWidth, alignment: .trailing)
                }
                .frame(maxWidth: .infinity)
                HStack {
                    Text("First day of week")
                    Spacer()
                    Picker("First day of week", selection: $weekStartsMonday) {
                        Text("Monday").tag(true)
                        Text("Sunday").tag(false)
                    }
                    .onChange(of: weekStartsMonday) { _, _ in
                        store.updateWeekStartsMonday(weekStartsMonday)
                    }
                    .labelsHidden()
                    .frame(width: settingsControlWidth, alignment: .trailing)
                }
                .frame(maxWidth: .infinity)
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
                Text(codexDataDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Maintenance") {
                LabeledContent("History index") {
                    Button {
                        AppDelegate.shared?.dashboardCoordinator.rebuildHistoryIndex()
                    } label: {
                        Text("Rebuild")
                    }
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
        .onAppear {
            selectedSubscriptionProviderRaw = subscriptionProviderRaw
            cliProxyAPIEndpoint = DashboardPreferences.sharedDefaults().string(
                forKey: DashboardPreferences.cliProxyAPIEndpointKey
            ) ?? cliProxyAPIEndpoint
            cliProxyAPIManagementKey = DashboardKeychain.readManagementKey() ?? ""
            sub2APIEndpoint = DashboardPreferences.sharedDefaults().string(
                forKey: DashboardPreferences.sub2APIEndpointKey
            ) ?? sub2APIEndpoint
            sub2APIAdminToken = DashboardKeychain.readSub2APIAdminToken() ?? ""
            sub2APIAccountID = DashboardPreferences.sharedDefaults().string(
                forKey: DashboardPreferences.sub2APIAccountIDKey
            ) ?? ""
            reloadSub2APIAccounts()
        }
    }

    private var appVersionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    private var quotaIconPreviewWindows: [UsageQuotaWindow] {
        store.subscription?.windows.sorted { $0.windowMinutes < $1.windowMinutes } ?? []
    }

    private var selectedSubscriptionProvider: DashboardSubscriptionProvider {
        DashboardSubscriptionProvider(rawValue: selectedSubscriptionProviderRaw) ?? .default
    }

    private var hasSub2APIActivationCredentials: Bool {
        !sub2APIAdminToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (Int64(sub2APIAccountID.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }

    private var codexDataDescription: String {
        switch selectedSubscriptionProvider {
        case .default:
            "CodexDashboard reads local session, account, and quota metadata from this folder. Credentials never leave your Mac."
        case .cliProxyAPI:
            "CodexDashboard still reads local session metrics from this folder. Quota and account credentials are managed by CLIProxyAPI."
        case .sub2API:
            "CodexDashboard still reads local session metrics from this folder. Quota is read from Wei-Shaw/sub2api."
        }
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

    private func selectSubscriptionProvider(_ rawValue: String) {
        let provider = DashboardSubscriptionProvider(rawValue: rawValue) ?? .default
        cliProxyAPIValidationState = .idle
        sub2APIValidationState = .idle
        if provider == .cliProxyAPI,
           let configuration = DashboardPreferences.cliProxyAPIConfiguration() {
            cliProxyAPIEndpoint = configuration.baseURL.absoluteString
            cliProxyAPIManagementKey = configuration.managementKey
            subscriptionProviderRaw = provider.rawValue
            store.updateSubscriptionProvider(provider)
            activateCLIProxyAPIConfiguration()
            return
        }
        if provider == .sub2API,
           let configuration = DashboardPreferences.sub2APIConfiguration() {
            sub2APIEndpoint = configuration.baseURL.absoluteString
            sub2APIAdminToken = configuration.adminToken
            sub2APIAccountID = String(configuration.accountID)
            subscriptionProviderRaw = provider.rawValue
            store.updateSubscriptionProvider(provider)
            reloadSub2APIAccounts()
            activateSub2APIConfiguration()
            return
        }
        guard provider == .default else { return }
        subscriptionProviderRaw = provider.rawValue
        store.updateSubscriptionProvider(provider)
    }

    private func reloadSub2APIAccounts() {
        guard let url = URL(string: sub2APIEndpoint), !sub2APIAdminToken.isEmpty else { return }
        Task {
            sub2APIAccounts = await Sub2APIReader.accounts(baseURL: url, adminToken: sub2APIAdminToken)
        }
    }

    private func activateCLIProxyAPIConfiguration() {
        let endpoint = cliProxyAPIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else {
            cliProxyAPIValidationState = .invalid("Enter a valid HTTP or HTTPS service URL.")
            return
        }
        let managementKey = cliProxyAPIManagementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !managementKey.isEmpty else {
            cliProxyAPIValidationState = .invalid("Enter the CLIProxyAPI management key.")
            return
        }
        cliProxyAPIValidationState = .validating
        let configuration = CLIProxyAPIConfiguration(baseURL: url, managementKey: managementKey)
        Task {
            let result = await CLIProxyAPIReader.validate(using: configuration)
            guard selectedSubscriptionProvider == .cliProxyAPI else { return }
            guard result.isValid else {
                cliProxyAPIValidationState = .invalid(result.message)
                return
            }
            guard DashboardKeychain.saveManagementKey(managementKey) else {
                cliProxyAPIValidationState = .invalid("Could not save the management key to Keychain.")
                return
            }
            DashboardPreferences.sharedDefaults().set(
                url.absoluteString,
                forKey: DashboardPreferences.cliProxyAPIEndpointKey
            )
            cliProxyAPIEndpoint = url.absoluteString
            subscriptionProviderRaw = DashboardSubscriptionProvider.cliProxyAPI.rawValue
            selectedSubscriptionProviderRaw = subscriptionProviderRaw
            if store.subscriptionProvider == .cliProxyAPI {
                store.refreshSubscriptionProvider()
            } else {
                store.updateSubscriptionProvider(.cliProxyAPI)
            }
            cliProxyAPIValidationState = .valid(result.message)
        }
    }

    private func activateSub2APIConfiguration() {
        let endpoint = sub2APIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else {
            sub2APIValidationState = .invalid("Enter a valid HTTP or HTTPS service URL.")
            return
        }
        let adminToken = sub2APIAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !adminToken.isEmpty else {
            sub2APIValidationState = .invalid("Enter the sub2api admin access token.")
            return
        }
        let accountID = sub2APIAccountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let accountID = Int64(accountID), accountID > 0 else {
            sub2APIValidationState = .invalid("Enter a valid upstream account ID.")
            return
        }
        sub2APIValidationState = .validating
        let configuration = Sub2APIConfiguration(baseURL: url, adminToken: adminToken, accountID: accountID)
        Task {
            let result = await Sub2APIReader.validate(using: configuration)
            guard selectedSubscriptionProvider == .sub2API else { return }
            guard result.isValid else {
                sub2APIValidationState = .invalid(result.message)
                return
            }
            guard DashboardKeychain.saveSub2APIAdminToken(adminToken) else {
                sub2APIValidationState = .invalid("Could not save the admin access token to Keychain.")
                return
            }
            DashboardPreferences.sharedDefaults().set(
                url.absoluteString,
                forKey: DashboardPreferences.sub2APIEndpointKey
            )
            DashboardPreferences.sharedDefaults().set(
                String(accountID),
                forKey: DashboardPreferences.sub2APIAccountIDKey
            )
            sub2APIEndpoint = url.absoluteString
            subscriptionProviderRaw = DashboardSubscriptionProvider.sub2API.rawValue
            selectedSubscriptionProviderRaw = subscriptionProviderRaw
            if store.subscriptionProvider == .sub2API {
                store.refreshSubscriptionProvider()
            } else {
                store.updateSubscriptionProvider(.sub2API)
            }
            sub2APIValidationState = .valid(result.message)
        }
    }

    private func signInToSub2API() {
        let endpoint = sub2APIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else {
            sub2APIValidationState = .invalid("Enter a valid HTTP or HTTPS service URL.")
            return
        }
        let email = sub2APIAdminEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !sub2APIAdminPassword.isEmpty else {
            sub2APIValidationState = .invalid("Enter the admin email and password.")
            return
        }
        sub2APIValidationState = .validating
        let password = sub2APIAdminPassword
        Task {
            let result = await Sub2APIReader.signIn(email: email, password: password, baseURL: url)
            guard result.isValid, let accessToken = result.accessToken else {
                sub2APIValidationState = .invalid(result.message)
                return
            }
            sub2APIAdminToken = accessToken
            sub2APIAccounts = result.accounts
            if !result.accounts.contains(where: { String($0.id) == sub2APIAccountID }) {
                sub2APIAccountID = result.accounts.first.map { String($0.id) } ?? ""
            }
            sub2APIAdminPassword = ""
            sub2APIValidationState = .valid(result.message)
        }
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

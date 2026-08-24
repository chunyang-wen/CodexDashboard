import AppKit
import Combine
import CodexMetricsCore
import SwiftUI

private final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class StatusItemController: NSObject {
    static let accessibilityIdentifier = "com.chunyangwen.CodexDashboard.status-item"

    private let store: MenuBarStore
    private let defaults: UserDefaults
    private let commandHandler: (MenuBarPopoverCommand) -> Void
    private let statusItem: NSStatusItem
    private var panel: NSPanel?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var observations: [AnyCancellable] = []

    init(
        store: MenuBarStore,
        defaults: UserDefaults,
        commandHandler: @escaping (MenuBarPopoverCommand) -> Void
    ) {
        self.store = store
        self.defaults = defaults
        self.commandHandler = commandHandler
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemPressed(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.title = "Codex quota"
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.setAccessibilityElement(true)
        statusItem.button?.setAccessibilityRole(.menuBarItem)
        statusItem.button?.setAccessibilityTitle("Codex quota")
        statusItem.button?.setAccessibilityLabel("Codex quota")
        statusItem.button?.setAccessibilityIdentifier(Self.accessibilityIdentifier)
        statusItem.button?.setAccessibilityHelp("Opens Codex quota")
        statusItem.button?.toolTip = "Codex quota"
        observations = [
            store.$subscription.sink { [weak self] subscription in
                self?.updateIcon(for: subscription)
            },
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
                .sink { [weak self] _ in
                    self?.updateVisibility()
                    self?.updateIcon()
                }
        ]
        updateVisibility()
        updateIcon()
    }

    @objc private func statusItemPressed(_ sender: NSStatusBarButton?) {
        guard sender != nil, isVisible else { return }
        if panel?.isVisible == true {
            dismissPopover()
            return
        }
        store.loadMenuBar()
        let anchor = statusItemScreenFrame ?? .zero
        showPopover(anchor: anchor)
    }

    func dismissPopover() {
        removeClickMonitors()
        panel?.orderOut(nil)
        panel = nil
        store.releasePopover()
    }

    private func showPopover(anchor: NSRect) {
        store.loadPopover()
        let root = MenuBarDashboardView { [weak self] command in
            guard let self else { return }
            self.dismissPopover()
            self.commandHandler(command)
        }
        .environmentObject(store)
        let hostingController = NSHostingController(rootView: root)
        let panel = MenuBarPanel(contentViewController: hostingController)
        panel.styleMask = .borderless
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let size = NSSize(width: 390, height: 620)
        panel.setContentSize(size)
        panel.setFrameOrigin(panelOrigin(anchor: anchor, size: size))
        self.panel = panel
        hostingController.view.layoutSubtreeIfNeeded()
        panel.makeKeyAndOrderFront(nil)
        installClickMonitors()
    }

    private func panelOrigin(anchor: NSRect, size: NSSize) -> NSPoint {
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: size.width + 16, height: size.height + 16)
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let y = max(visible.minY + 8, anchor.minY - size.height)
        return NSPoint(x: x, y: y)
    }

    private func installClickMonitors() {
        removeClickMonitors()
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.dismissIfClickIsOutside()
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismissIfClickIsOutside() }
        }
    }

    private func dismissIfClickIsOutside() {
        let mouseLocation = NSEvent.mouseLocation
        guard let panel,
              panel.isVisible,
              !panel.frame.contains(mouseLocation),
              statusItemScreenFrame?.contains(mouseLocation) != true
        else { return }
        dismissPopover()
    }

    private var statusItemScreenFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func removeClickMonitors() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    private var isVisible: Bool {
        defaults.object(forKey: DashboardPreferences.showMenuBarIconKey) == nil
            || defaults.bool(forKey: DashboardPreferences.showMenuBarIconKey)
    }

    private func updateVisibility() {
        statusItem.isVisible = isVisible
        if !isVisible { dismissPopover() }
    }

    private func updateIcon() {
        updateIcon(for: store.subscription)
    }

    private func updateIcon(for subscription: SubscriptionSnapshot?) {
        guard let button = statusItem.button else { return }
        let windows = subscription?.windows.sorted { $0.windowMinutes < $1.windowMinutes } ?? []
        let style = MenuBarQuotaIconStyle(rawValue: defaults.string(forKey: DashboardPreferences.menuBarQuotaIconStyleKey) ?? "rings") ?? .rings
        let alert = (defaults.object(forKey: DashboardPreferences.showQuotaAlertMarkerKey) as? Bool == true)
            ? defaults.double(forKey: DashboardPreferences.quotaAlertUsedPercentKey)
            : nil
        button.image = MenuBarQuotaIconRenderer.image(windows: windows, style: style, alertRemainingPercent: alert)
        button.image?.isTemplate = alert == nil
        let quotaDescription = windows.isEmpty
            ? "Quota unavailable"
            : windows.map { "\($0.displayName) \(Int($0.remainingPercent.rounded()))% remaining" }.joined(separator: ", ")
        button.setAccessibilityValue(quotaDescription)
        button.toolTip = quotaDescription
    }
}

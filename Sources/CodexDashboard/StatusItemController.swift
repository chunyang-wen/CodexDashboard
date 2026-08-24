import AppKit
import Combine

@MainActor
final class StatusItemController: NSObject {
    static let accessibilityIdentifier = "com.chunyangwen.CodexDashboard.status-item"

    private let store: MenuBarStore
    private let popoverCoordinator: PopoverProcessCoordinator
    private let defaults: UserDefaults
    private let statusItem: NSStatusItem
    private var observations: [AnyCancellable] = []

    init(store: MenuBarStore, popoverCoordinator: PopoverProcessCoordinator, defaults: UserDefaults) {
        self.store = store
        self.popoverCoordinator = popoverCoordinator
        self.defaults = defaults
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
            store.$subscription.sink { [weak self] _ in self?.updateIcon() },
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
        guard let sender, isVisible else { return }
        store.loadMenuBar()
        let anchor = sender.window?.convertToScreen(sender.frame) ?? .zero
        popoverCoordinator.requestPopover(anchor: anchor)
    }

    private var isVisible: Bool {
        defaults.object(forKey: DashboardPreferences.showMenuBarIconKey) == nil
            || defaults.bool(forKey: DashboardPreferences.showMenuBarIconKey)
    }

    private func updateVisibility() {
        statusItem.isVisible = isVisible
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let windows = store.subscription?.windows.sorted { $0.windowMinutes < $1.windowMinutes } ?? []
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

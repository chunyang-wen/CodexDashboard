import Foundation

enum PopoverLifecycleCommand: String, Sendable {
    case ready
    case closing
    case focus
    case openDashboard
    case openSettings
    case quitProduct
}

enum PopoverProcessProtocol {
    static let readyNotification = Notification.Name("com.chunyangwen.CodexDashboard.PopoverUI.ready")
    static let hostToPopoverNotification = Notification.Name("com.chunyangwen.CodexDashboard.PopoverUI.host-command")
    static let popoverToHostNotification = Notification.Name("com.chunyangwen.CodexDashboard.PopoverUI.host-request")

    static let commandKey = "command"
    static let tokenKey = "launchToken"
    static let hostPIDKey = "hostPID"
    static let popoverPIDKey = "popoverPID"
    static let processIDKey = "processID"
    static let generationKey = "generation"
    static let anchorXKey = "anchorX"
    static let anchorYKey = "anchorY"
    static let anchorWidthKey = "anchorWidth"
    static let anchorHeightKey = "anchorHeight"

    static let launchTokenArgument = "--codex-popover-launch-token"
    static let hostPIDArgument = "--codex-popover-host-pid"
    static let generationArgument = "--codex-popover-generation"
    static let anchorXArgument = "--codex-popover-anchor-x"
    static let anchorYArgument = "--codex-popover-anchor-y"
    static let anchorWidthArgument = "--codex-popover-anchor-width"
    static let anchorHeightArgument = "--codex-popover-anchor-height"
}

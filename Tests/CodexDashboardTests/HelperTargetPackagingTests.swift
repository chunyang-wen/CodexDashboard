import Foundation
import XCTest

final class HelperTargetPackagingTests: XCTestCase {
    func testHelperTargetIsAnEmbeddedAgentAppWithoutHostOnlyServices() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("CodexDashboard.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let helperSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/CodexDashboardUI/HelperMain.swift"),
            encoding: .utf8
        )
        let helperViewSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/CodexDashboardUI/DashboardHelperView.swift"),
            encoding: .utf8
        )
        let popoverSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/CodexDashboard/MenuBarPopoverView.swift"),
            encoding: .utf8
        )
        let statusItemSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/CodexDashboard/StatusItemController.swift"),
            encoding: .utf8
        )
        let statusItemGateSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("docs/dashboard-menubar-popover-memory-gate.sh"),
            encoding: .utf8
        )
        let hostSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/CodexDashboard/CodexDashboardApp.swift"),
            encoding: .utf8
        )
        let coordinatorSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/CodexDashboard/DashboardProcessCoordinator.swift"),
            encoding: .utf8
        )
        let infoURL = repositoryRoot.appendingPathComponent("Sources/CodexDashboardUI/Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: infoURL) as? [String: Any])

        XCTAssertTrue(project.contains("CodexDashboardUI"))
        XCTAssertFalse(project.contains("CodexDashboardPopoverUI"))
        XCTAssertFalse(project.contains("com.chunyangwen.CodexDashboard.PopoverUI"))
        XCTAssertTrue(project.contains("com.chunyangwen.CodexDashboard.DashboardUI"))
        XCTAssertTrue(project.contains("dstPath = \"../Helpers\";"))
        XCTAssertTrue(project.contains("dstSubfolderSpec = 13;"))
        XCTAssertTrue(project.contains("CodeSignOnCopy"))
        XCTAssertTrue(project.contains("@executable_path/../../../../Frameworks"))
        XCTAssertEqual(info["LSUIElement"] as? Bool, true)
        XCTAssertEqual(info["CFBundleIconName"] as? String, "AppIcon")
        XCTAssertNil(info["CFBundleDocumentTypes"])
        XCTAssertFalse(project.contains("CodexDashboardUI" + " /* Sparkle"))
        XCTAssertFalse(helperSource.contains("Sparkle"))
        XCTAssertFalse(helperSource.contains("MenuBarExtra"))
        XCTAssertFalse(helperSource.contains("Settings {"))
        XCTAssertFalse(helperSource.contains("restoration"))
        XCTAssertFalse(helperSource.contains("Dashboard helper shell"))
        XCTAssertTrue(helperSource.contains("sendReadyIfWindowIsVisible"))
        XCTAssertTrue(helperSource.contains("focusDashboardWindow"))
        XCTAssertTrue(helperSource.contains("startHostWatchdog"))
        XCTAssertTrue(helperSource.contains("createDashboardWindow"))
        XCTAssertTrue(helperSource.contains("showDashboardWindow"))
        XCTAssertTrue(helperSource.contains("guard dashboardWindow == nil else { return }"))
        XCTAssertTrue(helperSource.contains("window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]"))
        XCTAssertTrue(helperSource.contains("window.titleVisibility = .hidden"))
        XCTAssertTrue(helperSource.contains("Refresh Metrics"))
        XCTAssertTrue(helperSource.contains("Settings…"))
        XCTAssertTrue(helperSource.contains("Check for Updates…"))
        XCTAssertTrue(helperSource.contains("Quit Codex Dashboard"))
        XCTAssertTrue(helperSource.contains("DashboardStore("))
        XCTAssertTrue(helperSource.contains("codexHome: launchCodexHome"))
        XCTAssertTrue(helperSource.contains("HelperLifecycleNotification.hostToHelper"))
        XCTAssertTrue(helperSource.contains("HelperLifecycleNotification.helperToHost"))
        XCTAssertFalse(helperSource.contains("case \"openSettings\": postCommandToHost"))
        XCTAssertFalse(helperSource.contains("case \"checkForUpdates\": postCommandToHost"))
        XCTAssertTrue(coordinatorSource.contains("openApplication(at: helperURL"))
        XCTAssertTrue(coordinatorSource.contains("selector: #selector(DistributedDashboardLifecycleObserver.receiveCommand(_:))"))
        XCTAssertTrue(coordinatorSource.contains("suspensionBehavior: .deliverImmediately"))
        XCTAssertTrue(coordinatorSource.contains("name: DashboardProcessProtocol.hostToHelperNotificationName"))
        XCTAssertFalse(coordinatorSource.contains("Process("))
        XCTAssertFalse(coordinatorSource.contains("openDocument"))

        XCTAssertTrue(helperViewSource.contains("DashboardHelperRoot"))
        XCTAssertTrue(helperSource.contains("ConversationDebuggerWindow"))
        XCTAssertTrue(hostSource.contains("DashboardProcessCoordinator"))
        XCTAssertTrue(hostSource.contains("dashboardCoordinator.requestDashboard()"))
        XCTAssertFalse(hostSource.contains("InitialDashboardOpener"))
        XCTAssertFalse(hostSource.contains("openWindow(id: \"dashboard\")"))
        XCTAssertFalse(hostSource.contains("MenuBarExtra("))
        XCTAssertTrue(statusItemSource.contains("NSStatusBar.system.statusItem"))
        XCTAssertTrue(statusItemSource.contains("com.chunyangwen.CodexDashboard.status-item"))
        XCTAssertTrue(statusItemSource.contains("setAccessibilityIdentifier"))
        XCTAssertTrue(statusItemSource.contains("setAccessibilityHelp"))
        XCTAssertTrue(statusItemSource.contains("MenuBarPanel"))
        XCTAssertTrue(statusItemSource.contains("MenuBarDashboardView"))
        XCTAssertFalse(statusItemSource.contains("PopoverProcessCoordinator"))
        XCTAssertTrue(statusItemGateSource.contains("com.chunyangwen.CodexDashboard.status-item"))
        XCTAssertTrue(statusItemGateSource.contains("refusing an ordinal click"))
        XCTAssertFalse(statusItemGateSource.contains("UI elements of menu bar 1)[26]"))
        XCTAssertTrue(popoverSource.contains("MenuBarDashboardView"))
        XCTAssertFalse(hostSource.contains("PopoverProcessCoordinator"))
    }
}

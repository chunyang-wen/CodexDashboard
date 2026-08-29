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
        let helperConfigurations = project
            .components(separatedBy: "\n\t\t};")
            .filter {
                $0.contains("INFOPLIST_FILE = Sources/CodexDashboardUI/Info.plist;")
            }
        let helperSources = project
            .components(separatedBy: "\n\t\t};")
            .first {
                $0.contains("isa = PBXSourcesBuildPhase;")
                    && $0.contains("A70000000000000000000001 /* HelperMain.swift in Sources */")
            }

        XCTAssertEqual(helperConfigurations.count, 2)
        for configuration in helperConfigurations {
            XCTAssertTrue(configuration.contains("PRODUCT_BUNDLE_IDENTIFIER = com.chunyangwen.CodexDashboard.DashboardUI;"))
            XCTAssertTrue(configuration.contains("CODE_SIGN_STYLE = Automatic;"))
            XCTAssertTrue(configuration.contains("INFOPLIST_FILE = Sources/CodexDashboardUI/Info.plist;"))
            XCTAssertFalse(configuration.contains("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;"))
        }
        XCTAssertTrue(project.contains("D50000000000000000000001 /* CodexDashboardUI */"))
        XCTAssertTrue(project.contains("D50000000000000000000001 /* CodexDashboardUI */ = {\n\t\t\tisa = PBXNativeTarget;"))
        XCTAssertFalse(project.contains("CodexDashboardPopoverUI"))
        XCTAssertFalse(project.contains("com.chunyangwen.CodexDashboard.PopoverUI"))
        XCTAssertNotNil(helperSources)
        XCTAssertTrue(project.contains("A70000000000000000000003 /* CodexDashboardUI.app in Embed Helpers */"))
        XCTAssertTrue(project.contains("dstPath = ../Helpers;"))
        XCTAssertTrue(project.contains("dstSubfolderSpec = 13;"))
        XCTAssertTrue(project.contains("CodeSignOnCopy"))
        XCTAssertTrue(project.contains("@executable_path/../../../../Frameworks"))
        XCTAssertEqual(info["LSUIElement"] as? Bool, false)
        XCTAssertNil(info["CFBundleIconName"])
        XCTAssertNil(info["CFBundleDocumentTypes"])
        XCTAssertFalse(project.contains("CodexDashboardUI" + " /* Sparkle"))
        XCTAssertFalse(project.contains("A70000000000000000000002 /* Assets.xcassets in Resources */"))
        XCTAssertTrue(helperSource.contains("func applicationWillFinishLaunching"))
        XCTAssertTrue(helperSource.contains("Resources/AppIcon.icns"))
        XCTAssertTrue(helperSource.contains("NSApp.applicationIconImage = hostIcon"))
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
        XCTAssertTrue(helperSource.contains("appMenuItem.title = \"CodexDashboard\""))
        XCTAssertFalse(helperSource.contains("globalMouseDownMonitor"))
        XCTAssertFalse(helperSource.contains("activateMenuBarHost"))
        XCTAssertTrue(helperSource.contains("NSApp.windowsMenu = windowMenu"))
        XCTAssertTrue(helperSource.contains("HelperLifecycleNotification.hostToHelper"))
        XCTAssertTrue(helperSource.contains("HelperLifecycleNotification.helperToHost"))
        XCTAssertFalse(helperSource.contains("case \"openSettings\": postCommandToHost"))
        XCTAssertFalse(helperSource.contains("case \"checkForUpdates\": postCommandToHost"))
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

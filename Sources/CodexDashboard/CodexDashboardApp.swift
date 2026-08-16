import SwiftUI

@main
struct CodexDashboardApp: App {
    @StateObject private var store = DashboardStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1060, minHeight: 700)
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
    }
}

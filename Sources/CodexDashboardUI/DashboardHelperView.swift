import SwiftUI

struct DashboardHelperRoot: View {
    @ObservedObject private var store: DashboardStore
    private let openConversation: @MainActor @Sendable (ConversationWindowRequest) -> Void

    init(store: DashboardStore, openConversation: @escaping @MainActor @Sendable (ConversationWindowRequest) -> Void) {
        _store = ObservedObject(wrappedValue: store)
        self.openConversation = openConversation
    }

    var body: some View {
        ContentView()
            .environmentObject(store)
            .environment(\.dashboardConversationOpenAction, DashboardConversationOpenAction(open: openConversation))
            .frame(minWidth: 1060, minHeight: 700)
    }
}

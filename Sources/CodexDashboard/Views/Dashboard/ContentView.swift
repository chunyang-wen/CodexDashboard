import Charts
import CodexMetricsCore
import SwiftUI

enum DashboardPage: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case projects = "Projects"
    case models = "Models"
    case billing = "Usage & Billing"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .projects: "folder"
        case .models: "cpu"
        case .billing: "dollarsign.circle"
        }
    }
}

struct ActivityIndicator: View {
    let size: CGFloat

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(size <= 16 ? .small : .regular)
            .frame(width: size, height: size)
            .accessibilityLabel("In progress")
    }
}

struct MetricProgressBar: View {
    let value: Double
    var total: Double = 1

    private var fraction: Double {
        guard total > 0, value.isFinite, total.isFinite else { return 0 }
        return min(1, max(0, value / total))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.tint)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: DashboardStore
    @State private var selection: DashboardPage? = .overview
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(DashboardPage.allCases, selection: $selection) { page in
                Label(page.rawValue, systemImage: page.icon).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("LOCAL DATA").font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(.secondary)
                    Text(store.codexHomeDisplayPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        } detail: {
            Group {
                if store.isLoading && !store.hasLoadedAnalytics {
                    VStack(spacing: 10) {
                        ActivityIndicator(size: 32)
                        Text("Loading metrics…")
                    }
                } else if let error = store.errorMessage, store.sessions.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn’t load metrics", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { store.load() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    page
                }
            }
            .overlay(alignment: .topTrailing) {
                if store.isUpdatingAnalytics {
                    AnalyticsUpdateOverlay(label: store.analyticsUpdateLabel)
                        .padding(18)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    columnVisibility = columnVisibility == .all ? .detailOnly : .all
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help(columnVisibility == .all ? "Hide Sidebar" : "Show Sidebar")
                .accessibilityLabel(columnVisibility == .all ? "Hide Sidebar" : "Show Sidebar")
            }
            ToolbarItemGroup {
                Picker("Aggregation", selection: Binding(
                    get: { store.range },
                    set: { store.updateRange($0) }
                )) {
                    ForEach(DashboardStore.Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 245)
                Button { store.load() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(store.isBusy ? "Restart metrics refresh now" : "Refresh metrics now")
                .accessibilityLabel(store.isBusy ? "Restart metrics refresh" : "Refresh metrics")
                if store.isEnriching && !store.isUpdatingAnalytics {
                    MetricProgressBar(value: store.enrichmentFraction)
                        .frame(width: 76)
                        .help(store.enrichmentLabel)
                    Text("\(store.enrichedSessions)/\(store.enrichmentTotal)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(store.enrichmentLabel)
                }
            }
        }
        .onAppear { store.updatePage(selection ?? .overview) }
        .onChange(of: selection) { _, page in
            if let page { store.updatePage(page) }
        }
    }

    @ViewBuilder private var page: some View {
        switch selection ?? .overview {
        case .overview: OverviewView()
        case .projects: ProjectsView()
        case .models: ModelsView()
        case .billing: BillingView()
        }
    }
}

private struct AnalyticsUpdateOverlay: View {
    let label: String

    var body: some View {
        HStack(spacing: 9) {
            ActivityIndicator(size: 16)
            Text(label)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.separator.opacity(0.55)))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

import Charts
import CodexMetricsCore
import SwiftUI

private struct ModelTrendChartData: Equatable {
    struct Sample: Identifiable, Equatable {
        let id: String
        let index: Int
        let model: String
        let modelIndex: Int
        let tokens: Double
        let cacheRate: Double
        let cacheHitRate: Double
        let tokenSeries: String
        let cacheSeries: String
    }

    let dates: [Date]
    private let allSamples: [Sample]
    let maximumTokens: Double

    init(points: [ModelPeriodMetric], models: [ModelMetric]) {
        // The chart shows one model page at a time. Do not retain period rows
        // for models that are not visible in this page.
        let modelNames = Set(models.map(\.model))
        let visiblePoints = points.filter { modelNames.contains($0.model) }
        let preparedDates = Array(Set(visiblePoints.map(\.start))).sorted()
        let preparedPointsByModel = Dictionary(grouping: visiblePoints, by: \.model).mapValues { values in
            Dictionary(uniqueKeysWithValues: values.map { ($0.start, $0) })
        }
        let preparedMaximumTokens = max(1, visiblePoints
            .map { max(0, Double($0.usage.total)) }
            .max() ?? 1)
        dates = preparedDates
        maximumTokens = preparedMaximumTokens
        allSamples = Self.makeSamples(
            dates: preparedDates,
            pointsByModel: preparedPointsByModel,
            maximumTokens: preparedMaximumTokens,
            models: models
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.dates == rhs.dates
            && lhs.maximumTokens == rhs.maximumTokens
            && lhs.allSamples == rhs.allSamples
    }

    func samples(from start: Int, to end: Int) -> [Sample] {
        guard start < end else { return [] }
        let modelCount = dates.isEmpty ? 0 : allSamples.count / dates.count
        let startOffset = start * modelCount
        let endOffset = min(end * modelCount, allSamples.count)
        guard startOffset < endOffset else { return [] }
        return Array(allSamples[startOffset..<endOffset])
    }

    private static func makeSamples(
        dates: [Date],
        pointsByModel: [String: [Date: ModelPeriodMetric]],
        maximumTokens: Double,
        models: [ModelMetric]
    ) -> [Sample] {
        var samples: [Sample] = []
        samples.reserveCapacity(dates.count * models.count)
        for (index, date) in dates.enumerated() {
            for (modelIndex, model) in models.enumerated() {
                let point = pointsByModel[model.model]?[date]
                let usage = point?.usage ?? .zero
                let cacheHitRate = min(1, max(0, usage.cacheHitRate))
                samples.append(Sample(
                    id: "\(model.model)-\(index)",
                    index: index,
                    model: model.model,
                    modelIndex: modelIndex,
                    tokens: max(0, Double(usage.total)),
                    cacheRate: cacheHitRate * maximumTokens,
                    cacheHitRate: cacheHitRate,
                    tokenSeries: "\(model.model) · tokens",
                    cacheSeries: "\(model.model) · cache"
                ))
            }
        }
        return samples
    }
}

private struct ModelTrendChart: View, @MainActor Equatable {
    private enum ScrollEdge {
        case older
        case newer
    }

    let data: ModelTrendChartData
    let models: [ModelMetric]
    let granularity: PeriodGranularity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredScrollEdge: ScrollEdge?
    @State private var hoveredIndex: Int?
    @State private var scrollPosition = 0.0
    @State private var dragStartScrollPosition: Double?
    @State private var hiddenModels = Set<String>()

    private var dates: [Date] {
        data.dates
    }

    private var visiblePeriodCount: Double { Double(min(30, max(1, dates.count))) }
    private var latestScrollPosition: Double { max(0, Double(dates.count) - visiblePeriodCount) }
    private var canScroll: Bool { Double(dates.count) > visiblePeriodCount }
    private var visibleStart: Int {
        min(max(0, Int(scrollPosition.rounded())), max(0, dates.count - Int(visiblePeriodCount)))
    }
    private var visibleEnd: Int { min(dates.count, visibleStart + Int(visiblePeriodCount)) }
    private var axisPositions: [Double] {
        let step = max(1, Int(ceil(visiblePeriodCount / 8)))
        let visibleCount = visibleEnd - visibleStart
        var positions = stride(from: 0, to: visibleCount, by: step).map { Double($0) + 0.5 }
        if visibleCount > 0 { positions.append(Double(visibleCount) - 0.5) }
        return Array(Set(positions)).sorted()
    }

    private var samples: [ModelTrendChartData.Sample] {
        data.samples(from: visibleStart, to: visibleEnd)
    }

    private var maximumTokens: Double {
        data.maximumTokens
    }

    private var cacheAxisPositions: [Double] {
        stride(from: 0, through: 1, by: 0.25).map { $0 * maximumTokens }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.data == rhs.data && lhs.models == rhs.models && lhs.granularity == rhs.granularity
    }

    var body: some View {
        let visibleSamples = samples.filter { isModelVisible($0.model) }

        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "Model trend",
                subtitle: "Same models as the summary table. Drag, swipe, or use the edge arrows to move through " + granularityLabel.lowercased() + " history.",
                definition: .periodUsage
            )

            if dates.isEmpty || models.isEmpty {
                Text("No model trend data is available yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else {
                legend
                Chart {
                    ForEach(visibleSamples) { sample in
                        tokenMark(for: sample)
                        cacheMark(for: sample)
                    }
                    if let hoveredIndex, dates.indices.contains(hoveredIndex) {
                        RuleMark(x: .value("Hovered period", Double(hoveredIndex - visibleStart)))
                            .lineStyle(.init(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(.secondary.opacity(0.72))
                    }
                }
                .transaction { $0.animation = nil }
                .chartXScale(
                    domain: -0.5...max(0.5, visiblePeriodCount - 0.5),
                    range: .plotDimension(startPadding: 20, endPadding: 24)
                )
                .chartYScale(domain: 0...maximumTokens)
                .chartXAxis {
                    AxisMarks(values: axisPositions) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.14))
                        AxisValueLabel {
                            if let position = value.as(Double.self), let label = axisLabel(at: position) {
                                Text(label)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(MetricFormatters.compactNumber(Int64(max(0, number))))
                                    .monospacedDigit()
                            }
                        }
                    }
                    AxisMarks(position: .trailing, values: cacheAxisPositions) { value in
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(cacheAxisLabel(number))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    ChartHoverOverlay(
                        proxy: proxy,
                        selectionAtX: { proxy, x in
                            guard let rawIndex: Double = proxy.value(atX: x) else { return nil }
                            return min(
                                max(visibleStart, visibleStart + Int(rawIndex.rounded())),
                                visibleEnd - 1
                            )
                        },
                        selection: $hoveredIndex,
                        card: { index in hoverCard(for: index, samples: visibleSamples) },
                        cardPosition: hoverCardPosition,
                        onDragChanged: { translation, frame in
                            guard canScroll else { return }
                            guard frame.width > 0 else { return }
                            if dragStartScrollPosition == nil {
                                dragStartScrollPosition = scrollPosition
                            }
                            let translatedPeriods = Double(translation.width / frame.width) * visiblePeriodCount
                            let proposed = (dragStartScrollPosition ?? scrollPosition) - translatedPeriods
                            setScrollPosition(proposed)
                            hoveredIndex = nil
                        },
                        onDragEnded: {
                            dragStartScrollPosition = nil
                        },
                        onTap: { _, _ in }
                    )
                }
                .frame(height: 320)
                .overlay {
                    if canScroll {
                        HStack(spacing: 0) {
                            edgeScrollControl(.older)
                            Spacer(minLength: 0)
                            edgeScrollControl(.newer)
                        }
                    }
                }
                .onAppear {
                    scrollPosition = latestScrollPosition
                }
                .onChange(of: data) { _, _ in
                    hoveredIndex = nil
                    hiddenModels = []
                    scrollPosition = latestScrollPosition
                }
                .onChange(of: granularity) { _, _ in
                    hoveredIndex = nil
                    scrollPosition = latestScrollPosition
                }
            }
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    Button {
                        toggleModel(model.model)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(seriesColor(index))
                                .frame(width: 7, height: 7)
                                .opacity(isModelVisible(model.model) ? 1 : 0.28)
                            Text(model.model)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary.opacity(isModelVisible(model.model) ? 1 : 0.45))
                                .fixedSize(horizontal: false, vertical: true)
                            Image(systemName: isModelVisible(model.model) ? "eye" : "eye.slash")
                                .font(.caption2)
                                .foregroundStyle(.secondary.opacity(0.65))
                        }
                    }
                    .buttonStyle(.plain)
                    .help(isModelVisible(model.model) ? "Hide \(model.model)" : "Show \(model.model)")
                    .accessibilityLabel("\(model.model) model curve")
                    .accessibilityValue(isModelVisible(model.model) ? "Shown" : "Hidden")
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: 6) {
                Capsule().fill(.primary.opacity(0.72)).frame(width: 18, height: 2)
                Text("Tokens").font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule().fill(.secondary.opacity(0.72)).frame(width: 5, height: 2)
                    }
                }
                Text("Cache hit rate").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isModelVisible(_ model: String) -> Bool {
        !hiddenModels.contains(model)
    }

    private func toggleModel(_ model: String) {
        if hiddenModels.contains(model) {
            hiddenModels.remove(model)
        } else {
            hiddenModels.insert(model)
        }
    }

    private func scroll(by amount: Double) {
        setScrollPosition(scrollPosition + amount)
    }

    private func setScrollPosition(_ proposed: Double) {
        // The rendered window already rounds to a period index; avoid publishing
        // fractional drag updates that cannot change the chart contents.
        let next = min(latestScrollPosition, max(0, proposed.rounded()))
        guard next != scrollPosition else { return }
        scrollPosition = next
    }

    @ViewBuilder private func edgeScrollControl(_ edge: ScrollEdge) -> some View {
        let canMove = edge == .older
            ? scrollPosition > 0
            : scrollPosition < latestScrollPosition

        if canMove {
            Button { scroll(by: edge == .older ? -15 : 15) } label: {
                Image(systemName: edge == .older ? "chevron.left" : "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 26, height: 44)
                    .background(.regularMaterial, in: Capsule())
                    .overlay {
                        Capsule().stroke(.separator.opacity(0.6), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.2), radius: 7, y: 3)
            }
            .buttonStyle(.plain)
            .help(edge == .older ? "Show older model trend" : "Show newer model trend")
            .accessibilityLabel(edge == .older ? "Show older model trend" : "Show newer model trend")
            .opacity(hoveredScrollEdge == edge ? 1 : 0.48)
            .scaleEffect(hoveredScrollEdge == edge ? 1 : 0.9)
            .offset(x: hoveredScrollEdge == edge ? 0 : (edge == .older ? -8 : 8))
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: hoveredScrollEdge)
            .onHover { isHovering in
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                    if isHovering {
                        hoveredScrollEdge = edge
                    } else if hoveredScrollEdge == edge {
                        hoveredScrollEdge = nil
                    }
                }
            }
        } else {
            Color.clear
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    private func tokenMark(for sample: ModelTrendChartData.Sample) -> some ChartContent {
        LineMark(
            x: .value("Period", Double(sample.index - visibleStart)),
            y: .value("Tokens", sample.tokens),
            series: .value("Series", sample.tokenSeries)
        )
        .interpolationMethod(.monotone)
        .foregroundStyle(seriesColor(sample.modelIndex))
        .lineStyle(.init(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }

    private func cacheMark(for sample: ModelTrendChartData.Sample) -> some ChartContent {
        LineMark(
            x: .value("Period", Double(sample.index - visibleStart)),
            y: .value("Cache hit rate", sample.cacheRate),
            series: .value("Series", sample.cacheSeries)
        )
        .interpolationMethod(.monotone)
        .foregroundStyle(seriesColor(sample.modelIndex).opacity(0.52))
        .lineStyle(.init(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [5, 4], dashPhase: 0))
    }

    private func hoverCard(for index: Int, samples: [ModelTrendChartData.Sample]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(axisPeriodLabel(dates[index]))
                .font(.caption.weight(.semibold))
            ForEach(samples.filter { $0.index == index }) { sample in
                HStack(alignment: .top, spacing: 7) {
                    Circle()
                        .fill(seriesColor(sample.modelIndex))
                        .frame(width: 7, height: 7)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sample.model)
                            .font(.caption2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(MetricFormatters.compactNumber(Int64(max(0, sample.tokens)))) tokens · \(sample.cacheHitRate.formatted(.percent.precision(.fractionLength(1)))) cache")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 270, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.separator.opacity(0.55)))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    private func hoverCardPosition(for location: CGPoint, in size: CGSize) -> CGPoint {
        let horizontalOffset: CGFloat = location.x < size.width / 2 ? 165 : -165
        let verticalOffset: CGFloat = location.y < size.height / 2 ? 122 : -122
        return CGPoint(
            x: min(max(140, location.x + horizontalOffset), max(140, size.width - 140)),
            y: min(max(122, location.y + verticalOffset), max(122, size.height - 122))
        )
    }

    private func seriesColor(_ index: Int) -> Color {
        [.blue, .purple, .teal, .orange, .pink, .indigo][index % 6]
    }

    private func axisLabel(at position: Double) -> String? {
        let index = visibleStart + Int(floor(position))
        guard dates.indices.contains(index) else { return nil }
        return axisPeriodLabel(dates[index])
    }

    private func cacheAxisLabel(_ value: Double) -> String {
        let cachePercent = value / maximumTokens
        return cachePercent.formatted(.percent.precision(.fractionLength(0)))
    }

    private var granularityLabel: String {
        switch granularity {
        case .day: "Daily"
        case .week: "Weekly"
        case .month: "Monthly"
        case .year: "Yearly"
        }
    }

    private func axisPeriodLabel(_ date: Date) -> String {
        switch granularity {
        case .day, .week: date.formatted(.dateTime.month(.abbreviated).day())
        case .month: date.formatted(.dateTime.year().month(.abbreviated))
        case .year: date.formatted(.dateTime.year())
        }
    }
}

struct ModelsView: View {
    @EnvironmentObject private var store: DashboardStore
    @State private var modelPage = 0
    private let modelPageSize = 4

    private var visibleModels: [ModelMetric] {
        store.models
    }

    private var modelPageSummary: String {
        guard store.modelCount > 0 else { return "0 models" }
        let safePage = min(modelPage, store.modelPageCount - 1)
        let start = safePage * modelPageSize
        let end = min(start + visibleModels.count, store.modelCount)
        return "Models \(start + 1)–\(end) of \(store.modelCount)"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ModelTrendChart(
                    data: ModelTrendChartData(points: store.modelTrendPeriods, models: visibleModels),
                    models: visibleModels,
                    granularity: store.range.granularity
                )
                .equatable()
                SectionHeader(
                    title: "Model portfolio",
                    subtitle: "All-time aggregated totals for the same models shown in the trend above."
                )
                modelPager
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                    GridRow {
                        Text("Model")
                        Text("Sessions")
                        MetricHelpLabel(title: "Tokens", definition: .totalTokens)
                        MetricHelpLabel(title: "Cache hit", definition: .cacheHitRate)
                        MetricHelpLabel(title: "Runtime", definition: .agentRuntime)
                        MetricHelpLabel(title: "Est. cost", definition: .estimatedCost)
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Divider().gridCellColumns(6)
                    ForEach(visibleModels) { model in
                        GridRow {
                            Text(model.model)
                                .fontWeight(.medium)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(model.sessions.formatted()).monospacedDigit()
                            Text(MetricFormatters.compactNumber(model.usage.total)).monospacedDigit()
                            Text((model.usage.cacheHitRate * 100).formatted(.percent.scale(1).precision(.fractionLength(1)))).monospacedDigit()
                            Text(MetricFormatters.duration(model.activeRuntime)).monospacedDigit()
                            Text(MetricFormatters.currency(model.estimatedCost)).monospacedDigit()
                        }
                    }

                    Divider().gridCellColumns(6)
                }
            }.padding(28)
        }
        .navigationTitle("Models")
        .onAppear {
            modelPage = min(modelPage, store.modelPageCount - 1)
            store.updateModelPage(modelPage)
        }
        .onChange(of: store.modelPageCount) { _, count in
            modelPage = min(modelPage, count - 1)
            store.updateModelPage(modelPage)
        }
    }

    private var modelPager: some View {
        HStack(spacing: 12) {
            Text(modelPageSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                modelPage = max(0, modelPage - 1)
                store.updateModelPage(modelPage)
            } label: {
                Label("Previous model page", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            .disabled(modelPage == 0)
            .help("Show previous models")
            Text("Page \(min(modelPage + 1, store.modelPageCount)) of \(store.modelPageCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 86)
            Button {
                modelPage = min(store.modelPageCount - 1, modelPage + 1)
                store.updateModelPage(modelPage)
            } label: {
                Label("Next model page", systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
            }
            .disabled(modelPage >= store.modelPageCount - 1)
            .help("Show next models")
        }
        .frame(maxWidth: .infinity)
    }
}


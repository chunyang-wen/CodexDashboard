import Charts
import CodexMetricsCore
import SwiftUI

private enum PriceSeries: String, CaseIterable, Identifiable {
    case input = "Input"
    case cachedInput = "Cached input"
    case output = "Output"

    var id: String { rawValue }
    var color: Color {
        switch self {
        case .input: .blue
        case .cachedInput: .teal
        case .output: .orange
        }
    }
}

private struct PriceObservation: Identifiable {
    let date: Date
    let price: ModelPrice
    let source: String
    let inputValue: Double
    let cachedInputValue: Double
    let outputValue: Double

    var id: Date { date }

    init(date: Date, price: ModelPrice, source: String) {
        self.date = date
        self.price = price
        self.source = source
        inputValue = price.inputPerMillion.doubleValue
        cachedInputValue = price.cachedInputPerMillion.doubleValue
        outputValue = price.outputPerMillion.doubleValue
    }

    func value(for series: PriceSeries) -> Double {
        switch series {
        case .input: inputValue
        case .cachedInput: cachedInputValue
        case .output: outputValue
        }
    }
}

private struct PriceChartPoint: Identifiable {
    let id: String
    let date: Date
    let series: PriceSeries
    let value: Double
}

struct ModelPricingView: View {
    let pricing: PricingHistory
    @State private var selectedModel = ""

    private var models: [String] {
        Array(pricing.schedules.last?.prices.keys ?? Dictionary<String, ModelPrice>().keys).sorted()
    }

    private var defaultModel: String {
        models.contains("gpt-5.6-sol") ? "gpt-5.6-sol" : (models.first ?? "")
    }

    private var model: String { models.contains(selectedModel) ? selectedModel : defaultModel }

    private var observations: [PriceObservation] {
        var result: [PriceObservation] = []
        var previous: ModelPrice?
        for schedule in pricing.schedules {
            guard let price = schedule.prices[model], price != previous else { continue }
            result.append(PriceObservation(
                date: schedule.effectiveAt,
                price: price,
                source: schedule.source ?? "Imported history"
            ))
            previous = price
        }
        return result
    }

    var body: some View {
        let preparedObservations = observations
        let currentPrice = preparedObservations.last?.price
        let chartPoints = PriceSeries.allCases.flatMap { series in
            preparedObservations.map { observation in
                PriceChartPoint(
                    id: "\(series.rawValue)|\(observation.date.timeIntervalSinceReferenceDate)",
                    date: observation.date,
                    series: series,
                    value: observation.value(for: series)
                )
            }
        }

        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                SectionHeader(
                    title: "Model prices",
                    subtitle: "USD per 1 million tokens. Price changes are saved locally when a new models.dev rate card is observed."
                )
                if models.isEmpty {
                    Text("No models")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Model", selection: Binding(
                        get: { model },
                        set: { selectedModel = $0 }
                    )) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }
            }

            if let currentPrice {
                HStack(spacing: 12) {
                    priceCard("Input", currentPrice.inputPerMillion, tint: .blue)
                    priceCard("Cached input", currentPrice.cachedInputPerMillion, tint: .teal)
                    priceCard("Output", currentPrice.outputPerMillion, tint: .orange)
                }

                Chart {
                    ForEach(chartPoints) { point in
                        LineMark(
                            x: .value("Observed", point.date),
                            y: .value("USD per million", point.value),
                            series: .value("Rate", point.series.rawValue)
                        )
                        .interpolationMethod(.stepEnd)
                        .lineStyle(.init(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(by: .value("Rate", point.series.rawValue))
                    }
                }
                .transaction { $0.animation = nil }
                .chartForegroundStyleScale([
                    PriceSeries.input.rawValue: PriceSeries.input.color,
                    PriceSeries.cachedInput.rawValue: PriceSeries.cachedInput.color,
                    PriceSeries.output.rawValue: PriceSeries.output.color
                ])
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(amount.formatted(.currency(code: "USD").precision(.fractionLength(0...3))))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .frame(height: 260)

                HStack {
                    Label(
                        "\(preparedObservations.count) saved rate card\(preparedObservations.count == 1 ? "" : "s") for \(model)",
                        systemImage: "clock.arrow.circlepath"
                    )
                    Spacer()
                    if let latest = preparedObservations.last {
                        Text("Latest: \(latest.source) · \(latest.date.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                EmptyState(title: "No price data", message: "Refresh prices to save the first models.dev rate card.")
                    .frame(height: 220)
            }
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.separator.opacity(0.45)))
    }

    private func priceCard(_ title: String, _ price: Decimal, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(price.formatted(.currency(code: "USD").precision(.fractionLength(0...4))))
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

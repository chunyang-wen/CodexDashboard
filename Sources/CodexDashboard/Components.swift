import CodexMetricsCore
import SwiftUI

enum MetricDefinition {
    case totalTokens
    case tokenComposition
    case agentRuntime
    case sessionSpan
    case firstTokenLatency
    case turnPercentiles
    case cacheHitRate
    case estimatedCost
    case subscriptionQuota
    case periodUsage
    case activeDays
    case costCoverage
    case toolAttribution
    case skillAttribution

    var helpText: String {
        switch self {
        case .totalTokens:
            "Final cumulative tokens reported by Codex for each session. Exact when a token_count event or indexed total exists."
        case .tokenComposition:
            "The chart shows each category as a share of total tokens. Input is split into uncached, cached, and cache-write prompt tokens; reasoning is a subset of output and is not added again."
        case .agentRuntime:
            "Sum of duration_ms from completed turns. Includes tool execution and model waiting inside a turn; excludes time between turns."
        case .sessionSpan:
            "Time from session creation to its last update. Includes idle gaps and should not be treated as working time."
        case .firstTokenLatency:
            "Mean time_to_first_token_ms for completed turns. Measures response startup, not total completion speed."
        case .turnPercentiles:
            "The 50th and 95th percentile completed-turn runtimes. P95 surfaces slow-tail turns hidden by averages."
        case .cacheHitRate:
            "Cached input divided by total input. A high rate usually lowers API-equivalent input cost."
        case .estimatedCost:
            "Uncached input × input rate + cached input × cached rate + output × output rate. API-equivalent estimate only; excludes tool-call fees and subscription terms."
        case .subscriptionQuota:
            "Latest plan, usage windows, credits, and reset timestamps reported by Codex. Quota percentage is account-provided, not inferred from local token totals."
        case .periodUsage:
            "Token deltas are grouped by token-event timestamp; runtime by turn completion. Sessions without detailed events are assigned to their last-update date."
        case .activeDays:
            "Distinct local calendar days with project session activity. A cadence metric, not a productivity score."
        case .costCoverage:
            "Share of total tokens with both a detailed token breakdown and a recognized model price. Low coverage means the estimate is incomplete."
        case .toolAttribution:
            "Tool names come from local rollout events. Cost is the API-equivalent model-token cost observed after tool calls, divided evenly when several calls precede one token event. It is not a vendor tool fee."
        case .skillAttribution:
            "A skill activation is inferred when Codex explicitly reads that skill's SKILL.md. Cost is the API-equivalent model-token cost observed after activation, divided evenly when several skills precede one token event. It overlaps tool cost and is not an additional charge."
        }
    }
}

struct MetricHelpLabel: View {
    let title: String
    let definition: MetricDefinition
    @State private var showingDefinition = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Button { showingDefinition.toggle() } label: {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show definition for \(title)")
            .accessibilityLabel("About \(title)")
            .accessibilityHint("Shows how this metric is calculated")
            .popover(isPresented: $showingDefinition, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.headline)
                    Text(definition.helpText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(idealWidth: 340, maxWidth: 380, alignment: .leading)
            }
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    var tint: Color = .accentColor
    var definition: MetricDefinition?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                if let definition {
                    MetricHelpLabel(title: title.uppercased(), definition: definition)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.45)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.45)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(value)
                .font(.system(.title, design: .rounded, weight: .semibold))
                .contentTransition(.numericText())
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.separator.opacity(0.45)))
    }
}

struct ToolCallsMetricCard: View {
    let calls: Int
    let tools: [ToolMetric]
    let detail: String
    @State private var showingBreakdown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 28, height: 28)
                    .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                MetricHelpLabel(title: "TOOL CALLS", definition: .toolAttribution)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.45)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { showingBreakdown = true } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(calls.formatted(.number.notation(.compactName)))
                        .font(.system(.title, design: .rounded, weight: .semibold))
                        .contentTransition(.numericText())
                    HStack(spacing: 5) {
                        Text(detail).lineLimit(2)
                        Image(systemName: "arrow.up.right.circle.fill")
                            .foregroundStyle(.indigo)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open tool frequency and attributed cost")
            .accessibilityLabel("Tool calls: \(calls). Open breakdown")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.separator.opacity(0.45)))
        .sheet(isPresented: $showingBreakdown) {
            ToolBreakdownView(tools: tools, totalCalls: calls)
        }
    }
}

struct ToolBreakdownView: View {
    let tools: [ToolMetric]
    let totalCalls: Int
    @Environment(\.dismiss) private var dismiss

    private var attributedCost: Decimal { tools.reduce(0) { $0 + $1.estimatedCost } }
    private var namedCalls: Int { tools.reduce(0) { $0 + $1.calls } }
    private var attributedCalls: Int { tools.reduce(0) { $0 + $1.attributedCalls } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                SectionHeader(
                    title: "Tool activity",
                    subtitle: "Frequency and model-token cost attributed to each tool.",
                    definition: .toolAttribution
                )
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 28) {
                summary("CALLS", totalCalls.formatted())
                summary("TOOLS", tools.count.formatted())
                summary("ATTRIBUTED COST", MetricFormatters.preciseCurrency(attributedCost))
                summary("COVERAGE", totalCalls > 0 ? Double(attributedCalls) / Double(totalCalls) : 0, percent: true)
            }
            .padding(16)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if tools.isEmpty {
                ContentUnavailableView(
                    "No tool-level detail yet",
                    systemImage: "hammer",
                    description: Text(totalCalls > 0 ? "The total came from older indexed data. Re-enrichment will add tool names when the rollout is available." : "No tool calls were recorded in this selection.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(tools) { tool in
                            HStack(spacing: 12) {
                                Image(systemName: "wrench.and.screwdriver.fill")
                                    .foregroundStyle(.indigo)
                                    .frame(width: 28, height: 28)
                                    .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(tool.tool).font(.body.monospaced().weight(.medium)).lineLimit(1)
                                    Text("\(tool.sessions) session\(tool.sessions == 1 ? "" : "s") · \(MetricFormatters.compactNumber(tool.attributedUsage.total)) attributed tokens")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text("\(tool.calls.formatted()) calls").monospacedDigit()
                                    Text(MetricFormatters.preciseCurrency(tool.estimatedCost))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .frame(minWidth: 95, alignment: .trailing)
                            }
                            .padding(12)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        }
                    }
                }
            }
            Text("\(namedCalls.formatted()) calls have tool names; costs exclude vendor fees and subscription terms.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 520)
    }

    private func summary(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2.weight(.bold)).tracking(0.7).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
        }
    }

    private func summary(_ label: String, _ value: Double, percent: Bool) -> some View {
        summary(label, value.formatted(.percent.precision(.fractionLength(0))))
    }
}

struct SkillCallsMetricCard: View {
    let calls: Int
    let skills: [SkillMetric]
    let detail: String
    @State private var showingBreakdown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.mint)
                    .frame(width: 28, height: 28)
                    .background(Color.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                MetricHelpLabel(title: "SKILL ACTIVATIONS", definition: .skillAttribution)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.45)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { showingBreakdown = true } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(calls.formatted(.number.notation(.compactName)))
                        .font(.system(.title, design: .rounded, weight: .semibold))
                        .contentTransition(.numericText())
                    HStack(spacing: 5) {
                        Text(detail).lineLimit(2)
                        Image(systemName: "arrow.up.right.circle.fill").foregroundStyle(.mint)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open skill frequency and attributed cost")
            .accessibilityLabel("Skill activations: \(calls). Open breakdown")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.separator.opacity(0.45)))
        .sheet(isPresented: $showingBreakdown) {
            SkillBreakdownView(skills: skills, totalCalls: calls)
        }
    }
}

private struct SkillBreakdownView: View {
    let skills: [SkillMetric]
    let totalCalls: Int
    @Environment(\.dismiss) private var dismiss

    private var attributedCost: Decimal { skills.reduce(0) { $0 + $1.estimatedCost } }
    private var attributedCalls: Int { skills.reduce(0) { $0 + $1.attributedCalls } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                SectionHeader(
                    title: "Skill activity",
                    subtitle: "Activations inferred from SKILL.md reads, with attributed model-token cost.",
                    definition: .skillAttribution
                )
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 28) {
                summary("ACTIVATIONS", totalCalls.formatted())
                summary("SKILLS", skills.count.formatted())
                summary("ATTRIBUTED COST", MetricFormatters.preciseCurrency(attributedCost))
                summary("COVERAGE", totalCalls > 0 ? Double(attributedCalls) / Double(totalCalls) : 0, percent: true)
            }
            .padding(16)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if skills.isEmpty {
                ContentUnavailableView(
                    "No skill activations",
                    systemImage: "sparkles",
                    description: Text("No explicit SKILL.md reads were detected in this selection.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(skills) { skill in
                            HStack(spacing: 12) {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.mint)
                                    .frame(width: 28, height: 28)
                                    .background(Color.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(skill.skill).font(.body.monospaced().weight(.medium)).lineLimit(1)
                                    Text("\(skill.sessions) session\(skill.sessions == 1 ? "" : "s") · \(MetricFormatters.compactNumber(skill.attributedUsage.total)) attributed tokens")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text("\(skill.calls.formatted()) activations").monospacedDigit()
                                    Text(MetricFormatters.preciseCurrency(skill.estimatedCost))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .frame(minWidth: 110, alignment: .trailing)
                            }
                            .padding(12)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        }
                    }
                }
            }
            Text("Skill cost overlaps tool cost and should not be added to the total estimate.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 520)
    }

    private func summary(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2.weight(.bold)).tracking(0.7).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
        }
    }

    private func summary(_ label: String, _ value: Double, percent: Bool) -> some View {
        summary(label, value.formatted(.percent.precision(.fractionLength(0))))
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String
    var definition: MetricDefinition?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let definition {
                MetricHelpLabel(title: title, definition: definition)
                    .font(.title2.weight(.semibold))
            } else {
                Text(title).font(.title2.weight(.semibold))
            }
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyState: View {
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: "chart.bar.xaxis", description: Text(message))
    }
}

extension Decimal {
    var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }
}

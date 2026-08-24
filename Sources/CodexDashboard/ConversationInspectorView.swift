import AppKit
import CodexMetricsCore
import SwiftUI

struct ConversationWindowRequest: Codable, Hashable, Sendable {
    let rolloutPath: String
    let sessionTitle: String
    let projectName: String
}

struct DashboardConversationOpenAction: @unchecked Sendable {
    let open: @MainActor @Sendable (ConversationWindowRequest) -> Void
}

private struct DashboardConversationOpenActionKey: EnvironmentKey {
    static let defaultValue: DashboardConversationOpenAction? = nil
}

extension EnvironmentValues {
    var dashboardConversationOpenAction: DashboardConversationOpenAction? {
        get { self[DashboardConversationOpenActionKey.self] }
        set { self[DashboardConversationOpenActionKey.self] = newValue }
    }
}

struct ConversationDebuggerWindow: View {
    let request: ConversationWindowRequest

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(request.sessionTitle, systemImage: "waveform.path.ecg.text")
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                    Label(request.projectName, systemImage: "folder.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.blue)
                }
                ConversationInspectorView(rolloutPath: request.rolloutPath, loadsAutomatically: true)
            }
            .padding(24)
        }
        .frame(minWidth: 720, minHeight: 520)
        .navigationTitle("Conversation Debugger")
    }
}

struct ConversationInspectorView: View {
    let rolloutPath: String
    var loadsAutomatically = false

    private enum Mode: String, CaseIterable, Identifiable {
        case timeline = "Timeline"
        case raw = "Raw events"
        var id: String { rawValue }
    }

    private enum DirectionFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case sent = "Sent"
        case received = "Received"
        var id: String { rawValue }
    }

    @State private var transcript: ConversationTranscript?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var mode: Mode = .timeline
    @State private var direction: DirectionFilter = .all
    @State private var expandedTimeline = Set<Int>()
    @State private var expandedRaw = Set<Int>()
    @State private var unredactedCopyItem: ConversationItem?
    @State private var copyRawUnredacted = false
    @State private var loadTask: Task<Void, Never>?

    private var filteredItems: [ConversationItem] {
        guard let transcript else { return [] }
        return switch direction {
        case .all: transcript.items
        case .sent: transcript.items.filter { $0.direction == .sent }
        case .received: transcript.items.filter { $0.direction == .received }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                SectionHeader(
                    title: "Conversation debugger",
                    subtitle: "Inspect the local rollout as a readable exchange or as its original JSON events."
                )
                Spacer()
                if transcript != nil {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }
            }

            privacyNotice

            if let errorMessage {
                ContentUnavailableView(
                    "Conversation unavailable",
                    systemImage: "text.bubble",
                    description: Text(errorMessage)
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else if isLoading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading the rollout locally…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else if transcript == nil {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.path.ecg.text")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.teal)
                    Text("Load conversation details").font(.headline)
                    Text("Nothing is loaded until you ask, and conversation content is never added to dashboard history.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                    Button("Load from rollout") { load() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, minHeight: 190)
            } else if filteredItems.isEmpty {
                ContentUnavailableView(
                    "No matching events",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Try another direction filter, or this rollout may not contain conversation payloads.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                controls
                if mode == .timeline { timeline } else { rawEvents }
                footer
            }
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.separator.opacity(0.45)))
        .onChange(of: rolloutPath) { _, _ in reset() }
        .task {
            if loadsAutomatically, transcript == nil, !isLoading { load() }
        }
        .onDisappear { loadTask?.cancel() }
        .confirmationDialog(
            "Copy without redaction?",
            isPresented: Binding(
                get: { unredactedCopyItem != nil },
                set: { if !$0 { unredactedCopyItem = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Copy original", role: .destructive) {
                guard let item = unredactedCopyItem else { return }
                copy(copyRawUnredacted ? item.prettyRawJSON : item.body)
                unredactedCopyItem = nil
            }
            Button("Cancel", role: .cancel) { unredactedCopyItem = nil }
        } message: {
            Text("Tool arguments and results can contain credentials, private files, or personal data.")
        }
    }

    private var privacyNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill").foregroundStyle(.teal)
            Text("On-demand and local only. Raw payloads can contain secrets; Copy attempts to redact common credential formats unless you explicitly choose the original.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Direction", selection: $direction) {
                ForEach(DirectionFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 230)

            Text("\(filteredItems.count) event\(filteredItems.count == 1 ? "" : "s")")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Button("Collapse all") {
                if mode == .timeline { expandedTimeline.removeAll() } else { expandedRaw.removeAll() }
            }
            .buttonStyle(.borderless)
            Button {
                let text = filteredItems.map { item in
                    "[\(item.direction.rawValue)] \(item.title)\n\(mode == .raw ? item.redactedRawJSON : item.redactedBody)"
                }.joined(separator: "\n\n")
                copy(text)
            } label: {
                Label("Copy redacted", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
        }
    }

    private var timeline: some View {
        LazyVStack(spacing: 9) {
            ForEach(filteredItems) { item in
                ConversationTimelineRow(
                    item: item,
                    isExpanded: binding(for: item.id, in: $expandedTimeline),
                    onCopyRedacted: { copy(item.redactedBody) },
                    onCopyOriginal: {
                        copyRawUnredacted = false
                        unredactedCopyItem = item
                    }
                )
            }
        }
    }

    private var rawEvents: some View {
        LazyVStack(spacing: 8) {
            ForEach(filteredItems) { item in
                RawConversationRow(
                    item: item,
                    isExpanded: binding(for: item.id, in: $expandedRaw),
                    onCopyRedacted: { copy(item.redactedRawJSON) },
                    onCopyOriginal: {
                        copyRawUnredacted = true
                        unredactedCopyItem = item
                    }
                )
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if let transcript, transcript.omittedOversizedRecords > 0 {
            Label(
                "\(transcript.omittedOversizedRecords) record\(transcript.omittedOversizedRecords == 1 ? " was" : "s were") omitted because each exceeded 2 MB.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption).foregroundStyle(.orange)
        }
        Text("Sent/received describes the model exchange, not literal network packets. Readable reasoning appears only when the rollout includes a summary or plaintext details; encrypted continuation state remains opaque.")
            .font(.caption).foregroundStyle(.tertiary)
    }

    private func binding(for id: Int, in set: Binding<Set<Int>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(id) },
            set: { expanded in
                if expanded { set.wrappedValue.insert(id) }
                else { set.wrappedValue.remove(id) }
            }
        )
    }

    private func load() {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        let path = rolloutPath
        loadTask = Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try ConversationParser.load(path: path) { Task.isCancelled }
                }.value
                guard !Task.isCancelled else { return }
                transcript = loaded
                expandedTimeline = Set(loaded.items.filter {
                    $0.kind == .userMessage || $0.kind == .assistantMessage
                }.prefix(12).map(\.id))
                isLoading = false
            } catch is CancellationError {
                isLoading = false
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func reset() {
        loadTask?.cancel()
        transcript = nil
        errorMessage = nil
        isLoading = false
        expandedTimeline.removeAll()
        expandedRaw.removeAll()
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct ConversationTimelineRow: View {
    let item: ConversationItem
    @Binding var isExpanded: Bool
    let onCopyRedacted: () -> Void
    let onCopyOriginal: () -> Void

    private var color: Color { item.direction == .sent ? .cyan : .orange }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(color).frame(width: 3)
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.body.isEmpty ? "No textual payload" : item.body)
                        .font(item.kind == .toolCall || item.kind == .toolResult ? .caption.monospaced() : .body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CopyMenu(onCopyRedacted: onCopyRedacted, onCopyOriginal: onCopyOriginal)
                }
                .padding(.top, 10)
            } label: {
                ConversationEventLabel(item: item, color: color)
            }
            .padding(12)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct RawConversationRow: View {
    let item: ConversationItem
    @Binding var isExpanded: Bool
    let onCopyRedacted: () -> Void
    let onCopyOriginal: () -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.prettyRawJSON)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                CopyMenu(onCopyRedacted: onCopyRedacted, onCopyOriginal: onCopyOriginal)
            }
            .padding(.top, 10)
        } label: {
            ConversationEventLabel(item: item, color: item.direction == .sent ? .cyan : .orange)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ConversationEventLabel: View {
    let item: ConversationItem
    let color: Color

    var body: some View {
        HStack(spacing: 9) {
            Text(item.direction.rawValue.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(color)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(color.opacity(0.12), in: Capsule())
            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer()
            if let callID = item.callID {
                Text(callID).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                    .frame(maxWidth: 150, alignment: .trailing)
            }
            if let date = item.date {
                Text(date.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CopyMenu: View {
    let onCopyRedacted: () -> Void
    let onCopyOriginal: () -> Void

    var body: some View {
        Menu {
            Button("Copy redacted", systemImage: "shield.lefthalf.filled", action: onCopyRedacted)
            Button("Copy original…", systemImage: "exclamationmark.triangle", action: onCopyOriginal)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

#if canImport(SwiftUI)
import SwiftUI
import SearchCore
import DeviceSearch

/// The search screen (design doc §2 and §9). Put it inside a `NavigationStack`.
public struct DeviceSearchView: View {
    @Bindable private var model: SearchViewModel
    @State private var isSearchPresented = false

    public init(model: SearchViewModel) {
        self.model = model
    }

    public var body: some View {
        List {
            if let correction = model.correction {
                Section { CorrectionBanner(showing: correction.showing, original: correction.original,
                                           searchOriginal: model.searchOriginalInstead) }
            }
            if let note = model.relaxationNote {
                Section { Text(note).font(.footnote).foregroundStyle(.secondary) }
            }
            if let message = model.snapshot?.noMatchesMessage {
                Section { Text(message).foregroundStyle(.secondary) }
            }
            if let summary = model.snapshot?.setSummary {
                Section { SetSummaryHeader(summary: summary) }
            }
            if let command = model.snapshot?.command {
                Section { CommandBar(command: command, run: model.runCommand) }
            }
            ForEach(model.groups) { group in
                Section(group.section.title) {
                    ForEach(group.results) { result in
                        Button { model.select(result) } label: { SearchResultRow(result: result) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .animation(.snappy, value: model.snapshot?.results.map(\.id))
        // P02: hold the next phase while the list is touched; apply on release.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !model.isInteracting { model.isInteracting = true } }
                .onEnded { _ in model.isInteracting = false }
        )
        .searchable(text: $model.text, isPresented: $isSearchPresented, prompt: Text("Search devices"))
        .onSubmit(of: .search) { model.submit() }
        .onChange(of: isSearchPresented) { _, presented in model.focusChanged(presented) }
        .onChange(of: model.announcement) { _, announcement in
            if let announcement { AccessibilityNotification.Announcement(announcement.text).post() }
        }
        .toolbar {
            if model.state == .refining {
                ToolbarItem(placement: .status) {
                    ProgressView().accessibilityLabel(Text("Refining results"))
                }
            }
            if model.showsVoiceButton {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: model.toggleVoice) {
                        Image(systemName: model.isListening ? "mic.fill" : "mic")
                    }
                    .accessibilityLabel(Text(model.isListening ? "Stop listening" : "Search by voice"))
                }
            }
        }
        .task { model.start() }
    }
}

/// "Showing results for X. Search for Y instead." (P05)
struct CorrectionBanner: View {
    let showing: String
    let original: String
    let searchOriginal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Showing results for **\(showing)**")
            Button("Search for “\(original)” instead", action: searchOriginal)
                .font(.footnote)
        }
    }
}

/// "31 devices" with type and room chips (P03).
struct SetSummaryHeader: View {
    let summary: SetSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.count == 1 ? "1 device" : "\(summary.count) devices").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(summary.types + summary.rooms, id: \.label) { chip in
                        Text("\(chip.label) \(chip.count)")
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The detected command and its targets (C16, Y05).
struct CommandBar: View {
    let command: DetectedCommand
    let run: () -> Void

    var body: some View {
        Button(action: run) {
            Label("\(command.verb.capitalized) \(command.targets.count == 1 ? "1 device" : "\(command.targets.count) devices")",
                  systemImage: "bolt.circle")
        }
    }
}
#endif

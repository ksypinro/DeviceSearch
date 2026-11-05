import SwiftUI
import SearchCore
import DeviceSearch
import DeviceSearchUI

/// `DeviceSearchScreen` from the app-target files, plus two demo additions: sample searches to tap and a
/// diagnostics bar that shows which phase produced the results and how long each step took.
struct DemoSearchScreen: View {
    @State private var model: SearchViewModel
    /// The model holds its coordinator weakly, so the screen keeps it alive.
    @State private var coordinator: SearchCoordinator
    private let router: AppRouter
    @AppStorage("showDiagnostics") private var showDiagnostics = true

    static let samples = [
        "bedrom ac", "lights except kitchen", "offline cameras", "turn off all lights",
        "something to cool the bedroom", "movie night", "samsng tv", "big screen", "tv 2",
    ]

    init(home: HomeSearch, services: AppSearchServices, router: AppRouter) {
        self.router = router
        let coordinator = SearchCoordinator(router: router, services: services)
        _coordinator = State(initialValue: coordinator)
        _model = State(initialValue: SearchViewModel(engine: home.engine, coordinator: coordinator,
                                                     voice: Self.makeVoice(), flags: services.flags))
    }

    var body: some View {
        NavigationStack {
            DeviceSearchView(model: model)
                .navigationTitle("Search")
                .safeAreaInset(edge: .top, spacing: 0) { samples }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if showDiagnostics { DiagnosticsBar(snapshot: model.snapshot, state: model.state) }
                }
        }
        // A term from Spotlight or Shortcuts runs as a submitted search.
        .onChange(of: router.pendingSearch, initial: true) { _, term in
            guard let term else { return }
            router.pendingSearch = nil
            model.text = term
            model.submit()
        }
    }

    private var samples: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.samples, id: \.self) { sample in
                    Button(sample) {
                        model.text = sample
                        model.submit()
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private static func makeVoice() -> (any VoiceTranscribing)? {
        #if os(iOS)
        return SpeechVoiceTranscriber()
        #else
        return nil
        #endif
    }
}

/// What the engine did for the latest snapshot: phase, timings, the re-rank gate and validator changes.
struct DiagnosticsBar: View {
    let snapshot: SearchSnapshot?
    let state: SearchUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let snapshot {
                let d = snapshot.diagnostics
                Text("\(phaseLabel(snapshot)) · \(snapshot.results.count) results · intent \(snapshot.query.intent.rawValue)")
                    .fontWeight(.semibold)
                Text(timings(d))
                if let gate = d.gate {
                    Text("Model gate: \(gate.outcome.rawValue) — \(gate.reason)")
                }
                if !d.validatorInterventions.isEmpty {
                    Text("Validator changed the model's answer: \(d.validatorInterventions.joined(separator: ", "))")
                }
            } else {
                Text("Type a search or tap a sample. Press Search (return) to submit: only submitted searches can use the model.")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func phaseLabel(_ snapshot: SearchSnapshot) -> String {
        let phase: String
        switch snapshot.phase {
        case .instant: phase = "Instant (lexical)"
        case .hybrid: phase = "Hybrid (+ meaning)"
        case .refined: phase = snapshot.isRefining ? "Refined (streaming)" : "Refined by the model"
        case .fallback: phase = "Fallback (model skipped or too slow)"
        }
        return state == .refining && snapshot.phase != .refined ? phase + " · refining…" : phase
    }

    private func timings(_ d: SearchDiagnostics) -> String {
        var parts = ["lexical \(format(d.parseDuration + d.retrieveDuration + d.fuseDuration))"]
        if let meaning = d.meaningDuration { parts.append("meaning \(format(meaning))") }
        if let refine = d.refineDuration { parts.append("model \(format(refine))") }
        parts.append("\(d.candidateCount) candidates")
        return parts.joined(separator: " · ")
    }

    private func format(_ duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return ms >= 1000 ? String(format: "%.2f s", ms / 1000) : String(format: "%.1f ms", ms)
    }
}

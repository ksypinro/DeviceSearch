import AppIntents
import SwiftUI
import SearchCore

/// The Ask tab: questions about the home answered by Apple Intelligence over Spotlight (`DeviceAsk`, iOS 27).
/// On iOS 26, on Intel simulators and without Apple Intelligence it explains why it is unavailable.
struct AskTab: View {
    let services: AppSearchServices
    let router: AppRouter

    var body: some View {
        NavigationStack {
            content.navigationTitle("Ask")
        }
    }

    @ViewBuilder private var content: some View {
        #if canImport(FoundationModels) && arch(arm64)
        if #available(iOS 27.0, *) {
            if let reason = DeviceAsk.unavailableReason {
                ContentUnavailableView("Ask isn't available", systemImage: "sparkles", description: Text(reason))
            } else {
                AskView(services: services, router: router)
            }
        } else {
            unsupported
        }
        #else
        unsupported
        #endif
    }

    private var unsupported: some View {
        ContentUnavailableView("Ask needs iOS 27", systemImage: "sparkles",
                               description: Text("Asking about your home uses Spotlight's search tool for Apple Intelligence."))
    }
}

#if canImport(FoundationModels) && arch(arm64)
@available(iOS 27.0, *)
private struct AskView: View {
    let services: AppSearchServices
    let router: AppRouter
    @State private var ask: DeviceAsk
    @State private var question = ""
    @State private var asked: String?
    @State private var answer: DeviceAnswer?
    @State private var devices: [DeviceEntity] = []
    @State private var isAsking = false

    static let samples = [
        "Which lights are on?",
        "Is anything offline?",
        "What's in the kitchen?",
        "Which devices did I use today?",
    ]

    init(services: AppSearchServices, router: AppRouter) {
        self.services = services
        self.router = router
        _ask = State(initialValue: DeviceAsk(services: services))
    }

    var body: some View {
        List {
            if let asked {
                Section {
                    if isAsking {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Searching your home…").foregroundStyle(.secondary)
                        }
                    } else if let answer {
                        if let failure = answer.failure {
                            Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                            if let detail = answer.detail {
                                Text(detail).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            }
                        } else {
                            Text(answer.text)
                        }
                    }
                } header: {
                    Text(asked)
                }
                if !isAsking, !devices.isEmpty {
                    Section("Devices") {
                        ForEach(devices, id: \.id) { device in
                            Button {
                                router.openDevice(id: device.id)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                    if let room = device.room {
                                        Text(room).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .appEntityIdentifier(EntityIdentifier(for: device))
                        }
                    }
                }
            } else {
                Section("Try") {
                    ForEach(Self.samples, id: \.self) { sample in
                        Button(sample) { submit(sample) }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                TextField("Ask about your home", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit { submit(question) }
                Button("Ask", systemImage: "arrow.up.circle.fill") { submit(question) }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .disabled(isAsking || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
            .background(.bar)
        }
    }

    private func submit(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAsking else { return }
        asked = text
        question = ""
        answer = nil
        devices = []
        isAsking = true
        Task {
            let result = await ask.ask(text)
            let entities = await services.entities(for: result.devices.map(\.rawValue))
            // Keep the order the search returned.
            let byID = Dictionary(entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            answer = result
            devices = result.devices.compactMap { byID[$0.rawValue] }
            isAsking = false
        }
    }
}
#endif

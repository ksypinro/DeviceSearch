import SwiftUI
import SearchCore
import DeviceSearch
import DeviceSearchUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Feature flags (each one is a remote kill switch in a real app), model status, learned names and reset.
struct DemoSettingsView: View {
    let services: AppSearchServices
    let store: DemoDeviceStore
    let home: HomeSearch?
    let switchHome: @MainActor (DemoDeviceStore.HomeSize) -> Void
    let resetData: () async -> Void

    @State private var flags = SearchFeatureFlags.allOn
    @State private var isConfirmingReset = false
    @AppStorage("showDiagnostics") private var showDiagnostics = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Home") {
                    Picker("Devices", selection: Binding(get: { store.size }, set: switchHome)) {
                        ForEach(DemoDeviceStore.HomeSize.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    flag("Meaning (embeddings, concepts)", \.semanticEnabled)
                    flag("Model re-rank", \.rerankEnabled)
                    flag("Model query rewrite", \.queryRewriteEnabled)
                    flag("Streaming re-rank", \.streamingRerankEnabled)
                    flag("Personal ranking", \.personalizationEnabled)
                    flag("Learned nicknames", \.nicknamesEnabled)
                    flag("Spotlight", \.spotlightEnabled)
                    flag("Voice search", \.voiceEnabled)
                } header: {
                    Text("Features")
                } footer: {
                    Text("Read on every search. Turn everything off but personal ranking to see milestone 1 alone.")
                }

                Section("Apple Intelligence") {
                    LabeledContent("On-device model", value: modelStatus)
                    LabeledContent("Low Power Mode", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "On (model skipped)" : "Off")
                }

                Section {
                    if let home {
                        NavigationLink("Learned names") {
                            NicknameSettingsView(model: nicknameModel(for: home))
                        }
                    }
                    Toggle("Show diagnostics bar", isOn: $showDiagnostics)
                    Button("Reset search data", role: .destructive) { isConfirmingReset = true }
                } footer: {
                    Text("Reset does what sign-out does: deletes embeddings, selection history, learned names and Spotlight entries, then reloads the home.")
                }
            }
            .navigationTitle("Settings")
            .onAppear { flags = services.flags.currentFlags() }
            .confirmationDialog("Reset search data?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { Task { await resetData() } }
            }
        }
    }

    private func flag(_ title: String, _ key: WritableKeyPath<SearchFeatureFlags, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { flags[keyPath: key] }, set: { value in
            flags[keyPath: key] = value
            services.flags.update { $0[keyPath: key] = value }
            Task { await services.flagsDidChange() }
        }))
    }

    private func nicknameModel(for home: HomeSearch) -> NicknameSettingsModel {
        NicknameSettingsModel(
            manager: services.personalization.store(for: store.size.homeID),
            deviceNames: { ids in
                let devices = await home.engine.devices(withIDs: ids)
                return Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.name) })
            },
            onChange: { await home.sync.requestRebuild() })
    }

    private var modelStatus: String {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return "Available"
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is off"
        case .unavailable(.deviceNotEligible): return "Not supported on this device"
        case .unavailable(.modelNotReady): return "Downloading or not ready"
        case .unavailable: return "Unavailable"
        }
        #else
        return "Not in this SDK"
        #endif
    }
}

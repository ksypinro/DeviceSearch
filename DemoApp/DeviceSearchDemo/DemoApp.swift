import AppIntents
import SwiftUI
import SearchCore
import DeviceSearch
import DeviceSearchUI

/// The demo app. Launch wiring follows `AppTarget/DeviceSearch/AppSetup.swift` (which is left out of this target
/// because it is the template version with an empty device list): the services and router are registered with
/// `AppDependencyManager` before any intent runs.
@main
struct DeviceSearchDemoApp: App {
    private let services: AppSearchServices
    @State private var router: AppRouter
    @State private var store: DemoDeviceStore

    init() {
        let services: AppSearchServices
        do {
            services = try AppSearchServices()
        } catch {
            fatalError("The bundled search knowledge base failed to load: \(error)")
        }
        let router = AppRouter()
        let store = DemoDeviceStore()
        AppDependencyManager.shared.add(dependency: services)
        AppDependencyManager.shared.add(dependency: router)
        // Siri, Shortcuts and Spotlight switch devices through the store, as a real app's control API would.
        AppDependencyManager.shared.add(dependency: DeviceControl { on, ids in
            await MainActor.run { store.setPower(on, for: ids) }
        })
        if !SpotlightComparison.isRequested && !SpotlightSelfTest.isRequested {
            services.openAtLaunch(store.size.homeID, devices: store.records, events: store.bridge.events)
        }
        self.services = services
        _router = State(initialValue: router)
        _store = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup {
            if SpotlightComparison.isRequested {
                SpotlightComparisonView(services: services)
            } else if SpotlightSelfTest.isRequested {
                SpotlightSelfTestView(services: services)
            } else {
                DemoRootView(services: services, router: router, store: store)
                    .routesSystemActivities(to: router)
            }
        }
    }
}

enum DemoTab: Hashable {
    case search, ask, devices, settings
}

/// Opens the active home's search, keeps it in sync with the demo store, and hosts the tabs.
struct DemoRootView: View {
    let services: AppSearchServices
    let router: AppRouter
    let store: DemoDeviceStore
    @State private var home: HomeSearch?
    @State private var openHomeID: HomeID?
    @State private var reloadToken = 0
    @State private var tab: DemoTab = .search
    @State private var commandMessage: String?

    var body: some View {
        TabView(selection: $tab) {
            Tab("Search", systemImage: "magnifyingglass", value: DemoTab.search) {
                if let home {
                    DemoSearchScreen(home: home, services: services, router: router)
                        .id("\(store.size.rawValue)-\(reloadToken)")
                } else {
                    ProgressView("Building the index…")
                }
            }
            Tab("Ask", systemImage: "sparkles", value: DemoTab.ask) {
                AskTab(services: services, router: router)
            }
            Tab("Devices", systemImage: "house", value: DemoTab.devices) {
                DevicesView(store: store, services: services)
            }
            Tab("Settings", systemImage: "gearshape", value: DemoTab.settings) {
                DemoSettingsView(services: services, store: store, home: home,
                                 switchHome: { size in store.switchHome(to: size) },
                                 resetData: resetSearchData)
            }
        }
        .task(id: "\(store.size.rawValue)-\(reloadToken)") { await openHome() }
        // Spotlight and Shortcuts hand a search term to the router; show the search tab to run it.
        .onChange(of: router.pendingSearch) { _, term in if term != nil { tab = .search } }
        .sheet(isPresented: Binding(get: { router.openedDevice != nil }, set: { if !$0 { router.openedDevice = nil } })) {
            if let id = router.openedDevice {
                DeviceDetailView(deviceID: id, store: store, services: services)
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(
            get: { router.pendingCommand != nil }, set: { if !$0 { router.pendingCommand = nil } }),
                            titleVisibility: .visible) {
            if let command = router.pendingCommand {
                Button(command.verb.capitalized) {
                    let changed = store.apply(command)
                    // One device switched from the app: Siri and Spotlight learn the habit.
                    if command.targets.count == 1, changed == 1, let device = store.device(command.targets[0]),
                       let on = device.poweredOn {
                        DeviceIntentDonation.power(on, device: DeviceEntity(record: DeviceRecord(device),
                                                                            knowledge: services.knowledge))
                    }
                    commandMessage = changed == 0 ? "Nothing to change — the demo only runs “turn on” and “turn off”."
                        : "\(command.verb.capitalized): \(changed) device\(changed == 1 ? "" : "s") changed."
                    router.pendingCommand = nil
                }
                Button("Cancel", role: .cancel) { router.pendingCommand = nil }
            }
        }
        .alert(commandMessage ?? "", isPresented: Binding(get: { commandMessage != nil }, set: { if !$0 { commandMessage = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private var confirmationTitle: String {
        guard let command = router.pendingCommand else { return "" }
        let count = command.targets.count
        return "\(command.verb.capitalized) \(count) device\(count == 1 ? "" : "s")?"
    }

    private func openHome() async {
        if let openHomeID, openHomeID != store.size.homeID { await services.close(openHomeID) }
        home = nil
        let homeID = store.size.homeID
        home = await services.open(homeID, devices: store.records, events: store.bridge.events)
        openHomeID = homeID
    }

    /// Same as sign-out: deletes embeddings, personalization and Spotlight entries, then reopens the home.
    private func resetSearchData() async {
        await services.signOut()
        openHomeID = nil
        store.reset()
        reloadToken += 1
    }
}

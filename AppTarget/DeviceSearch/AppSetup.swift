import AppIntents
import SwiftUI
import SearchCore
import DeviceSearch
import DeviceSearchUI

/// Launch wiring. Merge into your `App` (or app delegate): register the dependencies before any intent runs,
/// then open the active home's search when its devices load.
@main
struct HomeApp: App {
    private let services: AppSearchServices
    @State private var router: AppRouter

    init() {
        let services: AppSearchServices
        do {
            services = try AppSearchServices()
        } catch {
            fatalError("The bundled search knowledge base failed to load: \(error)")
        }
        let router = AppRouter()
        AppDependencyManager.shared.add(dependency: services)
        AppDependencyManager.shared.add(dependency: router)
        // Replace with your backend's control call; return the devices that changed.
        AppDependencyManager.shared.add(dependency: DeviceControl { _, _ in throw DeviceControlError.notConnected })
        self.services = services
        _router = State(initialValue: router)
    }

    var body: some Scene {
        WindowGroup {
            RootView(services: services, router: router)
                .routesSystemActivities(to: router)
        }
    }
}

/// Example root: loads the home, opens its search, keeps the index in sync and shows the search screen.
struct RootView: View {
    let services: AppSearchServices
    let router: AppRouter
    @State private var home: HomeSearch?

    var body: some View {
        Group {
            if let home {
                DeviceSearchScreen(home: home, services: services, router: router, voice: makeVoice())
            } else {
                ProgressView()
            }
        }
        .task {
            // Replace with your device store: the current devices and a stream of later snapshots.
            let devices: [DeviceRecord] = []
            let bridge = DeviceEventBridge(initial: devices)
            home = await services.open(HomeID("home-1"), devices: devices, events: bridge.events)
        }
    }

    private func makeVoice() -> (any VoiceTranscribing)? {
        #if os(iOS)
        return SpeechVoiceTranscriber()
        #else
        return nil
        #endif
    }
}

import SwiftUI
import SearchCore
import DeviceSearch
import DeviceSearchUI

/// The search screen for the active home. Present it from your home screen's search button.
struct DeviceSearchScreen: View {
    @State private var model: SearchViewModel
    /// The model holds its coordinator weakly, so the screen keeps it alive.
    @State private var coordinator: SearchCoordinator
    private let router: AppRouter

    init(home: HomeSearch, services: AppSearchServices, router: AppRouter, voice: (any VoiceTranscribing)?) {
        self.router = router
        let coordinator = SearchCoordinator(router: router, services: services)
        _coordinator = State(initialValue: coordinator)
        _model = State(initialValue: SearchViewModel(engine: home.engine, coordinator: coordinator,
                                                     voice: voice, flags: services.flags))
    }

    var body: some View {
        NavigationStack {
            DeviceSearchView(model: model)
                .navigationTitle("Search")
        }
        // A term from Spotlight or Shortcuts runs as a submitted search.
        .onChange(of: router.pendingSearch, initial: true) { _, term in
            guard let term else { return }
            router.pendingSearch = nil
            model.text = term
            model.submit()
        }
    }
}

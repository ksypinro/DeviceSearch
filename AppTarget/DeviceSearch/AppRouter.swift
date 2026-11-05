import Observation
import SearchCore
import DeviceSearchUI

/// The app's navigation state, reachable from App Intents (a `@Dependency`). Replace the bodies with your
/// coordinator's navigation calls.
@MainActor
@Observable
final class AppRouter {
    /// Device screen to show (your navigation path).
    var openedDevice: DeviceID?
    /// A search term from Spotlight or Shortcuts, consumed by the search screen.
    var pendingSearch: String?
    /// A command waiting for the person's confirmation.
    var pendingCommand: DetectedCommand?

    func openDevice(id: String) {
        openedDevice = DeviceID(id)
    }

    func showSearch(_ term: String) {
        pendingSearch = term
    }
}

/// Hands search actions to the app (MVVM-C, design doc §13 M03).
@MainActor
final class SearchCoordinator: SearchCoordinating {
    private let router: AppRouter
    private let services: AppSearchServices

    init(router: AppRouter, services: AppSearchServices) {
        self.router = router
        self.services = services
    }

    func openDevice(_ id: DeviceID) {
        router.openDevice(id: id.rawValue)
        Task { await services.recordUsage(of: id) }
    }

    /// Commands are confirmed before anything changes (design doc §14 Y05): the confirmation sheet calls your
    /// control intents or actions for `command.targets`.
    func perform(_ command: DetectedCommand) {
        router.pendingCommand = command
    }
}

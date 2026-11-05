import AppIntents

/// Opens a device from Spotlight, Siri or Shortcuts.
struct OpenDeviceIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Device"

    @Parameter(title: "Device", requestValueDialog: "Which device?")
    var target: DeviceEntity

    @Dependency private var router: AppRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        router.openDevice(id: target.id)
        return .result()
    }
}

/// Shows the app's own search screen for a term (Spotlight "Search in app", Shortcuts).
/// To adopt the Apple Intelligence search schema on iOS 26, annotate it with `@AppIntent(schema: .system.search)`
/// (deprecated from iOS 27; design doc §14 Y06).
struct SearchDevicesIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Search Devices"
    static let searchScopes: [StringSearchScope] = [.general]

    @Parameter var criteria: StringSearchCriteria

    @Dependency private var router: AppRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        router.showSearch(criteria.term)
        return .result()
    }
}

/// Siri phrases, also shown as Spotlight top hits. Phrases with a parameter are listed for the entities'
/// `suggestedEntities()`; `AppSearchServices` calls `updateAppShortcutParameters()` when devices or rooms change.
struct DeviceSearchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TurnOnDeviceIntent(),
                    phrases: ["Turn on \(\.$device) in \(.applicationName)",
                              "Switch on \(\.$device) in \(.applicationName)"],
                    shortTitle: "Turn On", systemImageName: "power")
        AppShortcut(intent: TurnOffDeviceIntent(),
                    phrases: ["Turn off \(\.$device) in \(.applicationName)",
                              "Switch off \(\.$device) in \(.applicationName)"],
                    shortTitle: "Turn Off", systemImageName: "poweroff")
        AppShortcut(intent: TurnOnRoomLightsIntent(),
                    phrases: ["Turn on the lights in \(\.$room) with \(.applicationName)",
                              "Turn on the \(\.$room) lights with \(.applicationName)"],
                    shortTitle: "Room Lights On", systemImageName: "lightbulb.fill")
        AppShortcut(intent: TurnOffRoomLightsIntent(),
                    phrases: ["Turn off the lights in \(\.$room) with \(.applicationName)",
                              "Turn off the \(\.$room) lights with \(.applicationName)"],
                    shortTitle: "Room Lights Off", systemImageName: "lightbulb.slash")
        AppShortcut(intent: OpenDeviceIntent(),
                    phrases: ["Open \(\.$target) in \(.applicationName)"],
                    shortTitle: "Open Device", systemImageName: "house")
        AppShortcut(intent: SearchDevicesIntent(),
                    phrases: ["Search devices in \(.applicationName)"],
                    shortTitle: "Search Devices", systemImageName: "magnifyingglass")
    }
}

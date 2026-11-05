import AppIntents
import SearchCore

/// Changes devices for Siri, Shortcuts and Spotlight without opening the app. Register one at launch with
/// `AppDependencyManager`, built on your backend's control call; it returns the devices that actually changed.
final class DeviceControl: Sendable {
    typealias SetPower = @Sendable (_ on: Bool, _ devices: [DeviceID]) async throws -> [DeviceID]

    private let setPowerHandler: SetPower

    init(setPower: @escaping SetPower) {
        self.setPowerHandler = setPower
    }

    func setPower(_ on: Bool, for devices: [DeviceID]) async throws -> [DeviceID] {
        try await setPowerHandler(on, devices)
    }
}

enum DeviceControlError: Error, CustomLocalizedStringResourceConvertible {
    case notSwitchable(String)
    case noLights(String)
    case notConnected
    case noneSwitchable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSwitchable(let name): "\(name) can't be turned on or off."
        case .noneSwitchable: "None of those devices can be turned on or off from a shortcut."
        case .noLights(let room): "There are no lights in \(room)."
        case .notConnected: "Device control isn't available yet."
        }
    }
}

/// Power intents only touch devices with an on/off state. Locks, cameras, doorbells and garage doors are never
/// switched from a background shortcut (design doc §14, sensitive actions).
private enum Power {
    static func set(_ on: Bool, _ device: DeviceEntity, services: AppSearchServices,
                    control: DeviceControl) async throws -> IntentDialog {
        let name = SpotlightItemMapping.displayName(name: device.name, room: device.room)
        guard services.knowledge.typeCard(id: device.typeID)?.powered == true,
              !SpotlightItemMapping.sensitiveTypes.contains(device.typeID) else {
            throw DeviceControlError.notSwitchable(name)
        }
        let id = DeviceID(device.id)
        let changed = try await control.setPower(on, for: [id])
        await services.recordUsage(of: id)
        let state = on ? "on" : "off"
        return changed.isEmpty ? "\(name) is already \(state)." : "Turned \(state) \(name)."
    }

    /// Several devices at once. Devices the single-device intents refuse are skipped and named in the reply.
    static func setMany(_ on: Bool, _ devices: [DeviceEntity], services: AppSearchServices,
                        control: DeviceControl) async throws -> IntentDialog {
        let switchable = devices.filter {
            services.knowledge.typeCard(id: $0.typeID)?.powered == true
                && !SpotlightItemMapping.sensitiveTypes.contains($0.typeID)
        }
        guard !switchable.isEmpty else { throw DeviceControlError.noneSwitchable }
        let ids = switchable.map { DeviceID($0.id) }
        let changed = try await control.setPower(on, for: ids)
        for id in changed { await services.recordUsage(of: id) }
        let state = on ? "on" : "off"
        let skipped = devices.filter { device in !switchable.contains { $0.id == device.id } }
            .map { SpotlightItemMapping.displayName(name: $0.name, room: $0.room) }
        let result = switch changed.count {
        case 0: "They're already \(state)."
        case 1: "Turned \(state) 1 device."
        default: "Turned \(state) \(changed.count) devices."
        }
        return skipped.isEmpty ? "\(result)" : "\(result) Skipped \(skipped.joined(separator: ", "))."
    }

    static func setLights(_ on: Bool, in room: RoomEntity, services: AppSearchServices,
                          control: DeviceControl) async throws -> IntentDialog {
        let lights = await services.lights(inRoom: room.id)
        guard !lights.isEmpty else { throw DeviceControlError.noLights(room.id) }
        let changed = try await control.setPower(on, for: lights)
        let state = on ? "on" : "off"
        switch changed.count {
        case 0: return "The lights in \(room.id) are already \(state)."
        case 1: return "Turned \(state) 1 light in \(room.id)."
        default: return "Turned \(state) \(changed.count) lights in \(room.id)."
        }
    }
}

struct TurnOnDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn On Device"
    static let description = IntentDescription("Turns a device on without opening the app.")
    /// Runs in the app process, where `DeviceControl` is registered (not in a widget or intents extension).
    @available(iOS 27.0, macOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Device", requestValueDialog: "Which device?")
    var device: DeviceEntity

    static var parameterSummary: some ParameterSummary { Summary("Turn on \(\.$device)") }

    @Dependency private var services: AppSearchServices
    @Dependency private var control: DeviceControl

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await Power.set(true, device, services: services, control: control))
    }
}

struct TurnOffDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Off Device"
    static let description = IntentDescription("Turns a device off without opening the app.")
    /// Runs in the app process, where `DeviceControl` is registered (not in a widget or intents extension).
    @available(iOS 27.0, macOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Device", requestValueDialog: "Which device?")
    var device: DeviceEntity

    static var parameterSummary: some ParameterSummary { Summary("Turn off \(\.$device)") }

    @Dependency private var services: AppSearchServices
    @Dependency private var control: DeviceControl

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await Power.set(false, device, services: services, control: control))
    }
}

struct TurnOnRoomLightsIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn On Room Lights"
    static let description = IntentDescription("Turns on every light in a room.")
    /// Runs in the app process, where `DeviceControl` is registered (not in a widget or intents extension).
    @available(iOS 27.0, macOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Room", requestValueDialog: "Which room?")
    var room: RoomEntity

    static var parameterSummary: some ParameterSummary { Summary("Turn on the lights in \(\.$room)") }

    @Dependency private var services: AppSearchServices
    @Dependency private var control: DeviceControl

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await Power.setLights(true, in: room, services: services, control: control))
    }
}

struct TurnOffRoomLightsIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Off Room Lights"
    static let description = IntentDescription("Turns off every light in a room.")
    /// Runs in the app process, where `DeviceControl` is registered (not in a widget or intents extension).
    @available(iOS 27.0, macOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Room", requestValueDialog: "Which room?")
    var room: RoomEntity

    static var parameterSummary: some ParameterSummary { Summary("Turn off the lights in \(\.$room)") }

    @Dependency private var services: AppSearchServices
    @Dependency private var control: DeviceControl

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await Power.setLights(false, in: room, services: services, control: control))
    }
}

/// A room of the active home, as named on its devices ("Bedroom").
/// "Turn off the TV, the fan and the bedroom lamp": several devices in one request. Siri and Shortcuts pass an
/// `EntityCollection` (iOS 27), which resolves its entities only when the intent runs.
@available(iOS 27.0, macOS 27.0, *)
struct TurnOnDevicesIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn On Devices"
    static let description = IntentDescription("Turns several devices on at once. Locks, cameras, doorbells and garage doors are skipped.")
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Devices", requestValueDialog: "Which devices?")
    var devices: EntityCollection<DeviceEntity>

    static var parameterSummary: some ParameterSummary { Summary("Turn on \(\.$devices)") }

    @Dependency private var services: AppSearchServices
    @Dependency private var control: DeviceControl

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await Power.setMany(true, devices.resolvedEntities(), services: services, control: control))
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct TurnOffDevicesIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Off Devices"
    static let description = IntentDescription("Turns several devices off at once. Locks, cameras, doorbells and garage doors are skipped.")
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Devices", requestValueDialog: "Which devices?")
    var devices: EntityCollection<DeviceEntity>

    static var parameterSummary: some ParameterSummary { Summary("Turn off \(\.$devices)") }

    @Dependency private var services: AppSearchServices
    @Dependency private var control: DeviceControl

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await Power.setMany(false, devices.resolvedEntities(), services: services, control: control))
    }
}

struct RoomEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Room"
    static let defaultQuery = RoomEntityQuery()

    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)", image: .init(systemName: "door.left.hand.open"))
    }
}

/// Rooms come from the active home's devices, so App Shortcut phrases list the rooms people actually have.
struct RoomEntityQuery: EntityStringQuery {
    @Dependency private var services: AppSearchServices

    func entities(for identifiers: [RoomEntity.ID]) async throws -> [RoomEntity] {
        let rooms = Set(await services.rooms())
        return identifiers.filter(rooms.contains).map(RoomEntity.init)
    }

    func entities(matching string: String) async throws -> [RoomEntity] {
        await services.rooms().filter { $0.localizedStandardContains(string) }.map(RoomEntity.init)
    }

    func suggestedEntities() async throws -> [RoomEntity] {
        await services.rooms().map(RoomEntity.init)
    }
}

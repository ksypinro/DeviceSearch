import Foundation
import Observation
import SearchCore
import SearchTestSupport

/// The demo's device model, standing in for a real app's backend model. It conforms to `SearchableDevice`
/// exactly as the integration guide asks a real model to.
struct DemoDevice: Identifiable, Hashable, SearchableDevice {
    var id: String
    var name: String
    var manufacturer: String
    /// The knowledge-base type id ("ac", "light", …). `DeviceTypeMapping` passes unknown identifiers through,
    /// so the demo can use the ids directly as its "backend" identifiers.
    var type: String
    var room: String?
    var online: Bool?
    var poweredOn: Bool?
    var uses: Int
    var favorite: Bool
    var lastUsed: Date?

    var searchID: String { id }
    var displayName: String { name }
    var manufacturerName: String { manufacturer }
    var typeIdentifier: String { type }
    var roomName: String? { room }
    var isOnline: Bool? { online }
    var isPoweredOn: Bool? { poweredOn }
    var useCount: Int { uses }
    var isFavorite: Bool { favorite }
    var lastUsedAt: Date? { lastUsed }

    init(_ record: DeviceRecord) {
        id = record.id.rawValue
        name = record.name
        manufacturer = record.manufacturer
        type = record.type.rawValue
        room = record.room
        online = record.status?.isOnline
        poweredOn = record.status?.isOn
        uses = record.usage?.useCount ?? 0
        favorite = record.usage?.isFavorite ?? false
        lastUsed = record.usage?.lastUsedAt
    }
}

/// Stands in for the app's persistent store and live cache. Every change is published to the
/// `DeviceEventBridge`, which keeps the search index in step with what the screen shows.
@MainActor
@Observable
final class DemoDeviceStore {
    enum HomeSize: String, CaseIterable, Identifiable {
        case curated, large

        var id: String { rawValue }

        var title: String {
            switch self {
            case .curated: "Sample home (48 devices)"
            case .large: "Large home (500 devices)"
            }
        }

        var homeID: HomeID { HomeID("demo-\(rawValue)") }

        func makeDevices() -> [DemoDevice] {
            let records = self == .curated ? SyntheticHome.curated : SyntheticHome.make(count: 500)
            return records.map(DemoDevice.init)
        }
    }

    private(set) var size: HomeSize
    private(set) var devices: [DemoDevice]
    @ObservationIgnored private(set) var bridge: DeviceEventBridge

    init(size: HomeSize = .large) {
        let devices = size.makeDevices()
        self.size = size
        self.devices = devices
        self.bridge = DeviceEventBridge(initial: devices.map(DeviceRecord.init))
    }

    var records: [DeviceRecord] { devices.map(DeviceRecord.init) }

    /// Devices grouped by room, rooms sorted by name.
    var rooms: [(name: String, devices: [DemoDevice])] {
        Dictionary(grouping: devices) { $0.room ?? "No room" }
            .map { (name: $0.key, devices: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.name < $1.name }
    }

    func device(_ id: DeviceID) -> DemoDevice? {
        devices.first { $0.id == id.rawValue }
    }

    func update(_ id: String, _ change: (inout DemoDevice) -> Void) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        change(&devices[index])
        bridge.publish(records)
    }

    func remove(_ id: String) {
        devices.removeAll { $0.id == id }
        bridge.publish(records)
    }

    func addDevice(name: String, type: String, room: String) {
        var device = DemoDevice(DeviceRecord(id: DeviceID("demo-\(UUID().uuidString)"), name: name, manufacturer: "Demo",
                                             type: DeviceTypeID(type), room: room,
                                             status: DeviceStatus(isOnline: true, isOn: false)))
        device.uses = 0
        devices.append(device)
        bridge.publish(records)
    }

    /// Applies a confirmed "turn on/off …" command. Other verbs are only acknowledged in the demo.
    /// Returns how many devices changed.
    @discardableResult
    func apply(_ command: DetectedCommand) -> Int {
        let verb = command.verb.lowercased()
        let power: Bool? = verb.hasSuffix(" off") || verb == "shut" || verb == "deactivate" ? false
            : verb.hasSuffix(" on") || verb == "activate" ? true : nil
        guard let power else { return 0 }
        return setPower(power, for: command.targets).count
    }

    /// Switches devices on or off (the demo's stand-in for a control API) and returns those that changed.
    @discardableResult
    func setPower(_ on: Bool, for ids: [DeviceID]) -> [DeviceID] {
        let targets = Set(ids.map(\.rawValue))
        var changed: [DeviceID] = []
        for index in devices.indices where targets.contains(devices[index].id) && devices[index].poweredOn != on {
            devices[index].poweredOn = on
            changed.append(DeviceID(devices[index].id))
        }
        if !changed.isEmpty { bridge.publish(records) }
        return changed
    }

    /// Reloads the current home's sample devices (reset search data). The caller reopens the home's search.
    func reset() {
        bridge.finish()
        devices = size.makeDevices()
        bridge = DeviceEventBridge(initial: records)
    }

    /// Replaces the home. The caller opens the new home's search with the new bridge.
    func switchHome(to size: HomeSize) {
        guard size != self.size else { return }
        bridge.finish()
        self.size = size
        devices = size.makeDevices()
        bridge = DeviceEventBridge(initial: records)
    }
}

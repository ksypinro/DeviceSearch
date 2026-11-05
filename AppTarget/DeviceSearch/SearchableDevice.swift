import Foundation
import SearchCore

/// What the search package needs from the app's device model (design doc §4). Make your existing model
/// conform with a small extension; nothing else in the app has to change.
protocol SearchableDevice {
    var searchID: String { get }
    var displayName: String { get }
    var manufacturerName: String { get }
    /// The backend's type identifier, mapped to a knowledge-base type id by `DeviceTypeMapping`.
    var typeIdentifier: String { get }
    var roomName: String? { get }
    /// nil when the device reports no state (a lock without status, for example).
    var isOnline: Bool? { get }
    var isPoweredOn: Bool? { get }
    var useCount: Int { get }
    var isFavorite: Bool { get }
    var lastUsedAt: Date? { get }
}

/// Backend type identifiers → knowledge-base type ids (types.json). Unknown identifiers fall back to the
/// identifier itself, which the knowledge base maps to "other". Edit the table for your backend.
enum DeviceTypeMapping {
    static let table: [String: String] = [
        "air_conditioner": "ac", "aircon": "ac", "light": "light", "bulb": "light", "lamp": "light",
        "television": "tv", "tv": "tv", "thermostat": "thermostat", "lock": "lock", "door_lock": "lock",
        "camera": "camera", "doorbell": "doorbell", "plug": "plug", "outlet": "plug", "speaker": "speaker",
        "fan": "fan", "sensor": "sensor", "vacuum": "vacuum", "blinds": "blind", "garage_door": "garage",
    ]

    static func typeID(for identifier: String) -> String {
        table[identifier.lowercased()] ?? identifier.lowercased()
    }
}

extension DeviceRecord {
    init(_ device: some SearchableDevice) {
        let status: DeviceStatus? = device.isOnline.map { DeviceStatus(isOnline: $0, isOn: device.isPoweredOn) }
        self.init(id: DeviceID(device.searchID), name: device.displayName, manufacturer: device.manufacturerName,
                  type: DeviceTypeID(DeviceTypeMapping.typeID(for: device.typeIdentifier)), room: device.roomName,
                  status: status,
                  usage: UsageStats(useCount: device.useCount, isFavorite: device.isFavorite, lastUsedAt: device.lastUsedAt))
    }
}

import SearchCore

/// A change to the home's devices (design doc §11). Emit these from the same place your live cache reduces
/// actions — optimistic updates and saga compensations included — so search always matches what the UI shows.
public enum DeviceEvent: Sendable, Equatable {
    /// A device was added or its searchable fields changed (name, manufacturer, type, room).
    case upserted(DeviceRecord)
    case removed(DeviceID)
    /// Online or power state changed. Takes the fast path: no rebuild.
    case statusChanged(DeviceID, DeviceStatus?)
    /// Use count or favorite changed. Takes the fast path: priors are recomputed, no rebuild.
    case usageChanged(DeviceID, UsageStats?)
    /// A full sync replaced every device.
    case replacedAll([DeviceRecord])
}

/// Turns two device lists into events. Use it when your store exposes state snapshots instead of granular events.
public enum DeviceEventDiffer {
    public static func diff(old: [DeviceRecord], new: [DeviceRecord]) -> [DeviceEvent] {
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let current = Set(new.map(\.id))
        var events: [DeviceEvent] = []
        for device in new {
            guard let before = previous[device.id] else {
                events.append(.upserted(device))
                continue
            }
            if before.contentHash != device.contentHash {
                events.append(.upserted(device))
                continue
            }
            if before.status != device.status { events.append(.statusChanged(device.id, device.status)) }
            if before.usage != device.usage { events.append(.usageChanged(device.id, device.usage)) }
        }
        for device in old where !current.contains(device.id) {
            events.append(.removed(device.id))
        }
        return events
    }
}

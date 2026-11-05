import SearchCore
import SearchIndex
import SearchKnowledge

/// Shared fixtures: the bundled knowledge base and ready-made snapshots.
public enum TestIndex {
    /// The bundled knowledge base, loaded once.
    public static let knowledge: KnowledgeBase = {
        do { return try KnowledgeBase.bundled() } catch { fatalError("Bundled knowledge base failed to load: \(error)") }
    }()

    public static let builder = IndexBuilder(knowledge: knowledge)

    /// A snapshot of the given devices.
    public static func snapshot(_ devices: [DeviceRecord], homeID: HomeID = "test-home") -> IndexSnapshot {
        builder.build(homeID: homeID, devices: devices)
    }

    /// The 48 curated devices.
    public static let curated: IndexSnapshot = snapshot(SyntheticHome.curated)

    /// The lab's 500-device home (seed 7).
    public static let home500: IndexSnapshot = snapshot(SyntheticHome.make(count: 500))

    /// A small hand-made home with a custom room and an unknown manufacturer.
    public static let tiny: IndexSnapshot = snapshot([
        DeviceRecord(id: "t1", name: "Bedroom AC", manufacturer: "Samsung Electronics", type: "ac", room: "Bedroom",
                     status: DeviceStatus(isOnline: true, isOn: true), usage: UsageStats(useCount: 10, isFavorite: true)),
        DeviceRecord(id: "t2", name: "LivingRoomTV", manufacturer: "LG", type: "tv", room: "Lounge",
                     status: DeviceStatus(isOnline: true, isOn: false)),
        DeviceRecord(id: "t3", name: "Ayaan's Lamp", manufacturer: "Acme Gadgets", type: "light", room: "Ayaan's Room",
                     status: DeviceStatus(isOnline: false, isOn: nil)),
        DeviceRecord(id: "t4", name: "Front Door", manufacturer: "August", type: "lock", room: "Entrance"),
    ])
}

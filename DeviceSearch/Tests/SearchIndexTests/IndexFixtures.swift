import SearchCore
import SearchText
import SearchKnowledge
@testable import SearchIndex

/// Documents built directly with `DocumentBuilder`, so index structures can be tested before the snapshot
/// builder exists.
enum IndexFixtures {
    static let knowledge: KnowledgeBase = {
        do { return try KnowledgeBase.bundled() } catch { fatalError("Bundled knowledge base failed to load: \(error)") }
    }()

    static let pipeline = knowledge.makePipeline()

    /// The same four devices as `TestIndex.tiny`: a custom room, an unknown maker, a device without status.
    static let devices: [DeviceRecord] = [
        DeviceRecord(id: "t1", name: "Bedroom AC", manufacturer: "Samsung Electronics", type: "ac", room: "Bedroom",
                     status: DeviceStatus(isOnline: true, isOn: true), usage: UsageStats(useCount: 10, isFavorite: true)),
        DeviceRecord(id: "t2", name: "LivingRoomTV", manufacturer: "LG", type: "tv", room: "Lounge",
                     status: DeviceStatus(isOnline: true, isOn: false)),
        DeviceRecord(id: "t3", name: "Ayaan's Lamp", manufacturer: "Acme Gadgets", type: "light", room: "Ayaan's Room",
                     status: DeviceStatus(isOnline: false, isOn: nil)),
        DeviceRecord(id: "t4", name: "Front Door", manufacturer: "August", type: "lock", room: "Entrance"),
    ]

    static func documents(_ devices: [DeviceRecord] = devices) -> [SearchDocument] {
        let resolver = EntityResolver(knowledge: knowledge, pipeline: pipeline)
        let builder = DocumentBuilder(knowledge: knowledge, pipeline: pipeline)
        return devices.enumerated().map { ordinal, device in
            builder.makeDocument(ordinal: ordinal, device: device, brand: resolver.brand(for: device.manufacturer),
                                 room: resolver.room(for: device.room), aliases: [], prior: 0)
        }
    }
}

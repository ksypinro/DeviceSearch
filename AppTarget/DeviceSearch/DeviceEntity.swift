import AppIntents
import CoreSpotlight
import SearchCore
import SearchKnowledge
import SearchIndex

/// A device for Siri, Shortcuts and Spotlight (design doc §14 Y01). Lives in the app target (decision D07).
/// `SpotlightIndexer` indexes full items and associates this entity with them (`SpotlightItemMapping`).
struct DeviceEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Device"
    static let defaultQuery = DeviceEntityQuery()

    let id: String

    @Property(title: "Name")
    var name: String

    /// Indexed under a custom key, so Shortcuts' Find action can filter devices by type.
    @Property(title: "Type", customIndexingKey: SpotlightItemMapping.typeKey)
    var type: String

    @Property(title: "Manufacturer", customIndexingKey: SpotlightItemMapping.manufacturerKey)
    var manufacturer: String

    var typeID: String
    var room: String?
    /// Extra words Spotlight should match: a few type synonyms and learned nicknames.
    var keywords: [String]

    /// The title carries the room ("Bedroom AC"), matching the Spotlight result and telling apart devices that
    /// share a name.
    var displayRepresentation: DisplayRepresentation {
        let subtitle = [type, manufacturer].filter { !$0.isEmpty }.joined(separator: " · ")
        return DisplayRepresentation(title: "\(SpotlightItemMapping.displayName(name: name, room: room))",
                                     subtitle: "\(subtitle)",
                                     image: .init(systemName: SpotlightItemMapping.symbol(forType: typeID)))
    }

    var attributeSet: CSSearchableItemAttributeSet {
        SpotlightItemMapping.attributeSet(name: name, type: type, manufacturer: manufacturer, room: room,
                                          keywords: keywords)
    }

    init(id: String, name: String, type: String, typeID: String, manufacturer: String, room: String?,
         keywords: [String]) {
        self.id = id
        self.typeID = typeID
        self.room = room
        self.keywords = keywords
        self.name = name
        self.type = type
        self.manufacturer = manufacturer
    }

    init(record: DeviceRecord, knowledge: KnowledgeBase) {
        let card = knowledge.typeCard(for: record.type)
        self.init(id: record.id.rawValue, name: record.name, type: card.label, typeID: card.id,
                  manufacturer: record.manufacturer, room: record.room, keywords: Array(card.synonyms.prefix(4)))
    }

    init(result: SearchResult) {
        self.init(id: result.id.rawValue, name: result.device.name, type: result.typeLabel,
                  typeID: result.device.type.rawValue, manufacturer: result.device.manufacturer,
                  room: result.device.room, keywords: [])
    }

    /// For Spotlight: includes learned nicknames, so "big screen" finds the TV system-wide.
    init(document: SearchDocument) {
        self.init(id: document.id.rawValue, name: document.device.name, type: document.typeCard.label,
                  typeID: document.typeID, manufacturer: document.device.manufacturer, room: document.device.room,
                  keywords: Array(document.typeCard.synonyms.prefix(4)) + document.aliasTokens)
    }
}

/// Resolves devices for Siri, Shortcuts and Spotlight through the engine's fast path — lexical retrieval
/// only, never the model (design doc §14 Y02, Y03).
struct DeviceEntityQuery: EntityStringQuery {
    @Dependency private var services: AppSearchServices

    func entities(for identifiers: [DeviceEntity.ID]) async throws -> [DeviceEntity] {
        await services.entities(for: identifiers)
    }

    func entities(matching string: String) async throws -> [DeviceEntity] {
        await services.entities(matching: string, limit: 10)
    }

    /// Favorites and frequently used devices.
    func suggestedEntities() async throws -> [DeviceEntity] {
        await services.suggestedEntities(limit: 10)
    }
}

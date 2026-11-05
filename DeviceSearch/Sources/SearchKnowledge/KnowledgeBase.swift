import Foundation
import SearchCore
import SearchText

public enum KnowledgeBaseError: Error, Equatable {
    case missingResource(String)
    case invalid(String)
}

/// The domain ontology: device types, brands, rooms and the lexicon (design doc §6).
/// Ships as JSON in the package; a newer version can be loaded from a directory (remote config, decision X07).
public struct KnowledgeBase: Sendable {
    public let types: [DeviceTypeCard]
    public let brands: [BrandEntry]
    public let rooms: [RoomEntry]
    public let lexicon: Lexicon
    /// "t<types>.b<brands>.r<rooms>.l<lexicon>". A change triggers an index rebuild.
    public let version: String

    private let typeIndex: [String: Int]

    public init(types: [DeviceTypeCard], brands: [BrandEntry], rooms: [RoomEntry], lexicon: Lexicon,
                versions: (types: Int, brands: Int, rooms: Int) = (1, 1, 1)) throws {
        guard types.contains(where: { $0.id == Self.otherTypeID }) else {
            throw KnowledgeBaseError.invalid("types must include the '\(Self.otherTypeID)' type")
        }
        var index: [String: Int] = [:]
        for (position, card) in types.enumerated() {
            guard index[card.id] == nil else { throw KnowledgeBaseError.invalid("duplicate type id \(card.id)") }
            index[card.id] = position
        }
        guard Set(brands.map(\.id)).count == brands.count else { throw KnowledgeBaseError.invalid("duplicate brand id") }
        guard Set(rooms.map(\.id)).count == rooms.count else { throw KnowledgeBaseError.invalid("duplicate room id") }
        self.types = types
        self.brands = brands
        self.rooms = rooms
        self.lexicon = lexicon
        self.typeIndex = index
        self.version = "t\(versions.types).b\(versions.brands).r\(versions.rooms).l\(lexicon.version)"
    }

    /// Fallback card for device types the knowledge base does not know.
    public static let otherTypeID = "other"

    public var otherType: DeviceTypeCard { types[typeIndex[Self.otherTypeID]!] }

    /// The card for a device type; unknown ids map to the "other" card.
    public func typeCard(for id: DeviceTypeID) -> DeviceTypeCard {
        typeIndex[id.rawValue].map { types[$0] } ?? otherType
    }

    public func typeCard(id: String) -> DeviceTypeCard? { typeIndex[id].map { types[$0] } }

    /// The text pipeline configured with this lexicon's abbreviations and protected stems.
    public func makePipeline(segmenter: any WordSegmenting = PassthroughSegmenter()) -> TextPipeline {
        TextPipeline(
            segmenter: segmenter,
            normalizer: TextNormalizer(abbreviations: lexicon.abbreviations),
            stemmer: Stemmer(protected: Set(lexicon.protectedStems))
        )
    }

    /// Human label of a concept dimension ("cool" → "cooling").
    public func conceptLabel(_ dimension: String) -> String {
        lexicon.conceptLabels[dimension] ?? dimension
    }

    // MARK: Loading

    /// Loads the four JSON files shipped in this package.
    public static func bundled() throws -> KnowledgeBase {
        func url(_ name: String) throws -> URL {
            guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
                throw KnowledgeBaseError.missingResource("\(name).json")
            }
            return url
        }
        return try load(types: url("types"), brands: url("brands"), rooms: url("rooms"), lexicon: url("lexicon"))
    }

    /// Loads types.json, brands.json, rooms.json and lexicon.json from a directory (for example a remote update).
    public static func load(from directory: URL) throws -> KnowledgeBase {
        try load(types: directory.appendingPathComponent("types.json"),
                 brands: directory.appendingPathComponent("brands.json"),
                 rooms: directory.appendingPathComponent("rooms.json"),
                 lexicon: directory.appendingPathComponent("lexicon.json"))
    }

    public static func load(types: URL, brands: URL, rooms: URL, lexicon: URL) throws -> KnowledgeBase {
        let decoder = JSONDecoder()
        let typesFile = try decoder.decode(TypesFile.self, from: Data(contentsOf: types))
        let brandsFile = try decoder.decode(BrandsFile.self, from: Data(contentsOf: brands))
        let roomsFile = try decoder.decode(RoomsFile.self, from: Data(contentsOf: rooms))
        let lexiconValue = try decoder.decode(Lexicon.self, from: Data(contentsOf: lexicon))
        return try KnowledgeBase(types: typesFile.types, brands: brandsFile.brands, rooms: roomsFile.rooms,
                                 lexicon: lexiconValue,
                                 versions: (typesFile.version, brandsFile.version, roomsFile.version))
    }
}

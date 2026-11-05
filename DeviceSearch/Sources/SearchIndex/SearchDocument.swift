import SearchCore
import SearchKnowledge
import SearchText

/// BM25F fields (design doc §6). `alias` holds learned nicknames (milestone 4).
public enum SearchField: String, CaseIterable, Sendable, Hashable {
    case name, alias, type, brand, room
}

/// One device prepared for search. Built by `DocumentBuilder`; immutable inside a snapshot
/// except for live status and prior, which have fast-path updates.
public struct SearchDocument: Sendable {
    /// Position in the snapshot. Retrievers return ordinals; ties sort by ordinal.
    public let ordinal: Int
    public internal(set) var device: DeviceRecord
    public let typeCard: DeviceTypeCard
    public let brand: ResolvedBrand
    public let room: ResolvedRoom?
    /// Stemmed name tokens from both camel-split and unsplit normalization, de-duplicated, in order.
    public let nameTokens: [String]
    /// Stemmed tokens of learned nicknames.
    public let aliasTokens: [String]
    /// Tokens per BM25F field, including internal entity tokens ("§t:ac").
    public let fieldTokens: [SearchField: [String]]
    public let termFrequencies: [SearchField: [String: Int]]
    /// Every token in every field, without internal entity tokens. Used for query-word coverage.
    public let allTokens: Set<String>
    /// Normalized name without spaces, for trigrams ("livingroomtv2").
    public let compactKey: String
    /// Exact-name keys: stemmed tokens joined by spaces, camel-split and unsplit (one key when they agree).
    public let nameKeys: [String]
    public let trigrams: Set<String>
    /// Hash of name, manufacturer, type and room (see `DeviceRecord.contentHash`).
    public let contentHash: String
    /// Enriched description used for embeddings:
    /// "Bedroom AC. Air Conditioner (ac, aircon, cooler). Samsung. In Bedroom."
    public let embeddingText: String
    /// Usage and favorite prior, 0...1.
    public internal(set) var prior: Double

    public init(ordinal: Int, device: DeviceRecord, typeCard: DeviceTypeCard, brand: ResolvedBrand,
                room: ResolvedRoom?, nameTokens: [String], aliasTokens: [String],
                fieldTokens: [SearchField: [String]], allTokens: Set<String>, compactKey: String,
                embeddingText: String, prior: Double, nameKeys: [String] = [],
                sharedFrequencies: [SearchField: [String: Int]] = [:]) {
        self.ordinal = ordinal
        self.device = device
        self.typeCard = typeCard
        self.brand = brand
        self.room = room
        self.nameTokens = nameTokens
        self.aliasTokens = aliasTokens
        self.fieldTokens = fieldTokens
        // Fields shared by many documents (the type field) pass precomputed counts, so every document of a
        // type references one copy-on-write table instead of building its own.
        var frequencies = sharedFrequencies
        for (field, tokens) in fieldTokens where frequencies[field] == nil {
            var counts: [String: Int] = [:]
            for token in tokens { counts[token, default: 0] += 1 }
            frequencies[field] = counts
        }
        self.termFrequencies = frequencies
        self.allTokens = allTokens
        self.compactKey = compactKey
        self.nameKeys = nameKeys
        self.trigrams = Trigrams.of(compactKey)
        self.contentHash = device.contentHash
        self.embeddingText = embeddingText
        self.prior = prior
    }

    public var id: DeviceID { device.id }
    public var typeID: String { typeCard.id }
    public var brandID: String { brand.id }
    public var roomID: String? { room?.id }

    public func length(of field: SearchField) -> Int { fieldTokens[field]?.count ?? 0 }

    public func frequency(of term: String, in field: SearchField) -> Int { termFrequencies[field]?[term] ?? 0 }

    /// Room match strength for a room entity: 1 for the same room, 0.75 when the room name contains
    /// every word of the requested room ("bedroom" vs "Master Bedroom"), otherwise 0.
    public func roomMatch(id: String, tokens: [String]) -> Double {
        guard let room else { return 0 }
        if room.id == id { return 1 }
        if !tokens.isEmpty, tokens.allSatisfy(room.tokens.contains) { return 0.75 }
        return 0
    }
}

import Foundation
import SearchCore
import SearchText

/// A device's manufacturer resolved against the brand registry.
public struct ResolvedBrand: Hashable, Sendable {
    public var id: String
    public var name: String
    /// Phrases that name the brand (normalized), used for the brand field and the phrase dictionary.
    public var aliases: [String]
    /// False for manufacturers missing from brands.json (an ad-hoc brand).
    public var isKnown: Bool

    public init(id: String, name: String, aliases: [String], isKnown: Bool) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.isKnown = isKnown
    }
}

/// A device's room resolved against the room lexicon.
public struct ResolvedRoom: Hashable, Sendable {
    public var id: String
    /// The room name as the user wrote it, for display.
    public var name: String
    /// Stemmed tokens of `name`.
    public var tokens: [String]
    public var isKnown: Bool
    public var concepts: [String: Double]

    public init(id: String, name: String, tokens: [String], isKnown: Bool, concepts: [String: Double] = [:]) {
        self.id = id
        self.name = name
        self.tokens = tokens
        self.isKnown = isKnown
        self.concepts = concepts
    }
}

/// Resolves free-text manufacturer and room names (decisions D03, D04).
public struct EntityResolver: Sendable {
    private let pipeline: TextPipeline
    private let brands: [BrandEntry]
    /// Terms of each brand's name, in knowledge-base order.
    private let brandNameTerms: [[String]]
    /// (alias tokens, brand index), longest alias first; ties keep knowledge-base order.
    private let brandAliases: [(tokens: [String], brand: Int)]
    private let roomsByKey: [String: RoomEntry]

    public init(knowledge: KnowledgeBase, pipeline: TextPipeline) {
        self.pipeline = pipeline
        self.brands = knowledge.brands
        self.brandNameTerms = knowledge.brands.map { pipeline.terms($0.name) }
        var aliases: [(tokens: [String], brand: Int, order: Int)] = []
        for (index, brand) in knowledge.brands.enumerated() {
            for alias in [brand.name] + brand.aliases {
                let tokens = pipeline.terms(alias)
                if !tokens.isEmpty { aliases.append((tokens, index, aliases.count)) }
            }
        }
        aliases.sort { $0.tokens.count != $1.tokens.count ? $0.tokens.count > $1.tokens.count : $0.order < $1.order }
        self.brandAliases = aliases.map { ($0.tokens, $0.brand) }
        var rooms: [String: RoomEntry] = [:]
        for room in knowledge.rooms {
            for name in room.allNames {
                let key = pipeline.key(name)
                if !key.isEmpty, rooms[key] == nil { rooms[key] = room }
            }
        }
        self.roomsByKey = rooms
    }

    /// Resolution order: a brand whose name equals the manufacturer ("Philips" → Philips, not Philips Hue),
    /// then a brand with an alias equal to it, then the brand whose longest alias appears as consecutive words
    /// in it ("Samsung Electronics Co., Ltd." → Samsung). Unknown manufacturers become ad-hoc brands.
    public func brand(for manufacturer: String) -> ResolvedBrand {
        let tokens = pipeline.terms(manufacturer)
        func resolved(_ brand: BrandEntry) -> ResolvedBrand {
            ResolvedBrand(id: brand.id, name: brand.name, aliases: [brand.name] + brand.aliases, isKnown: true)
        }
        if let index = brandNameTerms.firstIndex(of: tokens) { return resolved(brands[index]) }
        if let alias = brandAliases.first(where: { $0.tokens == tokens }) { return resolved(brands[alias.brand]) }
        for alias in brandAliases where Self.containsRun(tokens, alias.tokens) {
            return resolved(brands[alias.brand])
        }
        let trimmed = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = tokens.isEmpty ? "unknown" : tokens.joined(separator: "-")
        return ResolvedBrand(id: "x-" + slug, name: trimmed.isEmpty ? "Unknown" : trimmed,
                             aliases: tokens.isEmpty ? [] : [tokens.joined(separator: " ")], isKnown: false)
    }

    /// The room lexicon entry with exactly the same name or alias ("Lounge" → Living Room),
    /// otherwise an ad-hoc room keyed by the name ("Ayaan's Room" → "room-ayaan-room").
    public func room(for name: String?) -> ResolvedRoom? {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let tokens = pipeline.terms(name)
        let key = tokens.joined(separator: " ")
        if let room = roomsByKey[key] {
            return ResolvedRoom(id: room.id, name: name, tokens: tokens, isKnown: true, concepts: room.concepts)
        }
        let slug = tokens.isEmpty ? "unnamed" : tokens.joined(separator: "-")
        return ResolvedRoom(id: "room-" + slug, name: name, tokens: tokens, isKnown: false)
    }

    static func containsRun(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }
}

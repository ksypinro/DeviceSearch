import Foundation
import SearchCore
import SearchKnowledge
import SearchText

/// Turns a `DeviceRecord` into a `SearchDocument` (design doc §6). Uses the same `TextPipeline` as the query parser.
public struct DocumentBuilder: Sendable {
    public let knowledge: KnowledgeBase
    public let pipeline: TextPipeline
    /// Type-field tokens per type card, computed once (every device of a type shares them).
    private let typeTokens: [String: [String]]
    /// The type field with its entity token ("§t:ac") and its term counts, shared by every device of the type.
    private let typeFields: [String: (tokens: [String], frequencies: [String: Int])]
    /// Terms of each knowledge-base room's canonical name.
    private let roomNameTerms: [String: [String]]
    /// The type part of the embedding text, per type card.
    private let typeTexts: [String: String]
    /// Type tokens as a set, the starting point of every document's `allTokens`.
    private let typeTokenSets: [String: Set<String>]

    public init(knowledge: KnowledgeBase, pipeline: TextPipeline) {
        self.knowledge = knowledge
        self.pipeline = pipeline
        var typeTokens: [String: [String]] = [:]
        var typeFields: [String: (tokens: [String], frequencies: [String: Int])] = [:]
        for card in knowledge.types {
            let tokens = Self.unique(card.allNames.flatMap { pipeline.terms($0) })
            typeTokens[card.id] = tokens
            let field = tokens + ["§t:" + card.id]
            var counts: [String: Int] = [:]
            for token in field { counts[token, default: 0] += 1 }
            typeFields[card.id] = (field, counts)
        }
        self.typeTokens = typeTokens
        self.typeFields = typeFields
        self.typeTexts = Dictionary(uniqueKeysWithValues: knowledge.types.map { ($0.id, Self.typeText($0)) })
        self.typeTokenSets = typeTokens.mapValues { Set($0) }
        var roomNameTerms: [String: [String]] = [:]
        for room in knowledge.rooms { roomNameTerms[room.id] = pipeline.terms(room.name) }
        self.roomNameTerms = roomNameTerms
    }

    /// Brand-field tokens: the brand name (camel-split and not) plus its aliases. Cache per brand when building.
    public func brandTokens(for brand: ResolvedBrand) -> [String] {
        Self.unique(pipeline.terms(brand.name) + pipeline.terms(brand.name, splitCamelCase: false)
                    + brand.aliases.flatMap { pipeline.terms($0) })
    }

    /// - Parameter brandTokens: `brandTokens(for: brand)`, when the caller caches it; computed otherwise.
    public func makeDocument(ordinal: Int, device: DeviceRecord, brand: ResolvedBrand, room: ResolvedRoom?,
                             aliases: [String], prior: Double, brandTokens cachedBrandTokens: [String]? = nil) -> SearchDocument {
        let card = knowledge.typeCard(for: device.type)

        // One normalization of the name serves the camel-split terms, the compact key and the exact key;
        // the unsplit form is normalized only when it differs ("LivingRoomTV").
        let normalizedName = pipeline.normalizedTokens(device.name)
        let camelTerms = normalizedName.map(pipeline.stemmer.stem)
        let plainTerms = TextNormalizer.hasCamelCaseBoundary(device.name)
            ? pipeline.terms(device.name, splitCamelCase: false) : camelTerms
        let nameTokens = unique(camelTerms + plainTerms)
        let nameKeys = unique([camelTerms.joined(separator: " "), plainTerms.joined(separator: " ")]).filter { !$0.isEmpty }
        let aliasTokens = unique(aliases.flatMap { pipeline.terms($0) })
        let typeTokens = self.typeTokens[card.id] ?? Self.unique(card.allNames.flatMap { pipeline.terms($0) })
        let brandTokens = cachedBrandTokens ?? self.brandTokens(for: brand)
        var roomTokens: [String] = []
        if let room {
            roomTokens = room.tokens
            if room.isKnown, let terms = roomNameTerms[room.id] {
                roomTokens = unique(roomTokens + terms)
            }
        }

        var fields: [SearchField: [String]] = [
            .name: nameTokens,
            .alias: aliasTokens,
            .type: typeFields[card.id]?.tokens ?? (typeTokens + ["§t:" + card.id]),
            .brand: brandTokens + ["§b:" + brand.id],
            .room: roomTokens,
        ]
        if let room { fields[.room]!.append("§r:" + room.id) }

        var allTokens = typeTokenSets[card.id] ?? Set(typeTokens)
        allTokens.formUnion(nameTokens)
        allTokens.formUnion(aliasTokens)
        allTokens.formUnion(brandTokens)
        allTokens.formUnion(roomTokens)
        let compactKey = normalizedName.joined()

        return SearchDocument(
            ordinal: ordinal, device: device, typeCard: card, brand: brand, room: room,
            nameTokens: nameTokens, aliasTokens: aliasTokens, fieldTokens: fields, allTokens: allTokens,
            compactKey: compactKey,
            embeddingText: Self.embeddingText(device: device, typeText: typeTexts[card.id] ?? Self.typeText(card),
                                              brand: brand, room: room),
            prior: prior, nameKeys: nameKeys,
            sharedFrequencies: typeFields[card.id].map { [.type: $0.frequencies] } ?? [:])
    }

    /// "Bedroom AC. Air Conditioner (ac, aircon, cooler). Samsung. In Bedroom."
    public static func embeddingText(device: DeviceRecord, card: DeviceTypeCard, brand: ResolvedBrand,
                                     room: ResolvedRoom?) -> String {
        embeddingText(device: device, typeText: typeText(card), brand: brand, room: room)
    }

    /// "Air Conditioner (ac, aircon, cooler)": the type part of the embedding text, the same for every device.
    public static func typeText(_ card: DeviceTypeCard) -> String {
        let synonyms = card.synonyms.filter { $0.filter(\.isLetter).count > 2 }.prefix(3)
        return synonyms.isEmpty ? card.label : card.label + " (" + synonyms.joined(separator: ", ") + ")"
    }

    static func embeddingText(device: DeviceRecord, typeText: String, brand: ResolvedBrand, room: ResolvedRoom?) -> String {
        var text = device.name + ". " + typeText + ". " + brand.name + "."
        if let room { text += " In " + room.name + "." }
        return text
    }

    func unique(_ tokens: [String]) -> [String] { Self.unique(tokens) }

    static func unique(_ tokens: [String]) -> [String] {
        var seen = Set<String>()
        return tokens.filter { seen.insert($0).inserted }
    }
}

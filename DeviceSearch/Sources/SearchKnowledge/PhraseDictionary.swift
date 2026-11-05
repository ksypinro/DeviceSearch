import SearchCore
import SearchText

public enum PhraseKind: String, Sendable, Hashable {
    case type, brand, room, status, negation, quantifier, preposition, generic, need, stop

    /// Types, brands and rooms are entities; everything else is a function word.
    public var isEntity: Bool { self == .type || self == .brand || self == .room }
}

public struct PhraseEntry: Hashable, Sendable {
    public var kind: PhraseKind
    /// Type id, brand id, room id or `StatusCondition` raw value. Empty for function words.
    public var id: String
    public var label: String
    /// For rooms: stemmed tokens of the room's display name.
    public var roomTokens: [String]

    public init(kind: PhraseKind, id: String = "", label: String = "", roomTokens: [String] = []) {
        self.kind = kind
        self.id = id
        self.label = label
        self.roomTokens = roomTokens
    }
}

/// Maps normalized, stemmed phrases of up to `maxPhraseLength` words to entities and function words
/// (design doc §5). Built from the knowledge base, then extended with the home's own rooms and brands (decision D03).
public struct PhraseDictionary: Sendable {
    public private(set) var entries: [String: [PhraseEntry]] = [:]
    /// Tokens of type, brand and room phrases. Seeds the vocabulary so typos can be corrected to them.
    public private(set) var entityTokens: Set<String> = []
    /// Tokens of function phrases. Never typo-corrected and never content.
    public private(set) var functionTokens: Set<String> = []
    public let maxPhraseLength: Int
    public let pipeline: TextPipeline

    public init(knowledge: KnowledgeBase, pipeline: TextPipeline, maxPhraseLength: Int = 4) {
        self.pipeline = pipeline
        self.maxPhraseLength = maxPhraseLength
        // The "other" card is a fallback, not something users search for ("device" is a generic noun).
        for card in knowledge.types where card.id != KnowledgeBase.otherTypeID {
            let entry = PhraseEntry(kind: .type, id: card.id, label: card.label)
            for name in card.allNames { add(name, entry) }
        }
        for brand in knowledge.brands {
            let entry = PhraseEntry(kind: .brand, id: brand.id, label: brand.name)
            for name in [brand.name] + brand.aliases { add(name, entry) }
        }
        for room in knowledge.rooms {
            addRoom(id: room.id, label: room.name, names: room.allNames)
        }
        let lexicon = knowledge.lexicon
        for phrase in lexicon.statusPhrases {
            add(phrase.phrase, PhraseEntry(kind: .status, id: phrase.condition.rawValue, label: phrase.condition.rawValue))
        }
        for word in lexicon.negations { add(word, PhraseEntry(kind: .negation)) }
        for word in lexicon.quantifiers { add(word, PhraseEntry(kind: .quantifier)) }
        for word in lexicon.roomPrepositions { add(word, PhraseEntry(kind: .preposition)) }
        for word in lexicon.genericNouns { add(word, PhraseEntry(kind: .generic)) }
        for word in lexicon.needWords { add(word, PhraseEntry(kind: .need)) }
        for word in lexicon.stopWords { add(word, PhraseEntry(kind: .stop)) }
    }

    /// Adds a phrase. Duplicate (kind, id) entries for the same phrase are ignored.
    public mutating func add(_ phrase: String, _ entry: PhraseEntry) {
        let terms = pipeline.terms(phrase)
        guard !terms.isEmpty, terms.count <= maxPhraseLength else { return }
        let key = terms.joined(separator: " ")
        var list = entries[key] ?? []
        if !list.contains(where: { $0.kind == entry.kind && $0.id == entry.id }) {
            list.append(entry)
            entries[key] = list
        }
        if entry.kind.isEntity {
            entityTokens.formUnion(terms)
        } else {
            functionTokens.formUnion(terms)
        }
    }

    /// Adds a room. Every name maps to the same room id; the label's tokens enable partial room matches.
    public mutating func addRoom(id: String, label: String, names: [String]) {
        let entry = PhraseEntry(kind: .room, id: id, label: label, roomTokens: pipeline.terms(label))
        for name in names { add(name, entry) }
    }

    public mutating func addBrand(id: String, label: String, names: [String]) {
        let entry = PhraseEntry(kind: .brand, id: id, label: label)
        for name in names { add(name, entry) }
    }

    public func entries(forKey key: String) -> [PhraseEntry] { entries[key] ?? [] }

    /// The longest phrase starting at `start`, trying `maxPhraseLength` words first.
    public func longestMatch(in terms: [String], from start: Int) -> (length: Int, entries: [PhraseEntry])? {
        guard start < terms.count else { return nil }
        let longest = min(maxPhraseLength, terms.count - start)
        for length in stride(from: longest, through: 1, by: -1) {
            let key = terms[start..<(start + length)].joined(separator: " ")
            if let found = entries[key], !found.isEmpty { return (length, found) }
        }
        return nil
    }

    public func isFunctionToken(_ token: String) -> Bool { functionTokens.contains(token) }
}

import SearchCore
import SearchText

/// One device type card (design doc §6): what the type is called, what it means, and how it relates to others.
public struct DeviceTypeCard: Codable, Sendable, Hashable, Identifiable {
    /// Matches `DeviceRecord.type.rawValue`.
    public var id: String
    public var label: String
    /// Two-letter badge shown on result rows.
    public var code: String
    /// English synonyms and common spellings, lowercase.
    public var synonyms: [String]
    /// One sentence used for embeddings and the model's glossary.
    public var description: String
    public var related: [String]
    public var capabilities: [String]
    /// Weights over the concept dimensions in lexicon.json (meaning fallback and tests).
    public var concepts: [String: Double]
    /// Labels per language code, for example ["bn": ["এসি"], "de": ["Klimaanlage"]].
    public var localized: [String: [String]]
    /// True when the type normally has an on/off state.
    public var powered: Bool

    public init(id: String, label: String, code: String, synonyms: [String], description: String,
                related: [String] = [], capabilities: [String] = [], concepts: [String: Double] = [:],
                localized: [String: [String]] = [:], powered: Bool = false) {
        self.id = id
        self.label = label
        self.code = code
        self.synonyms = synonyms
        self.description = description
        self.related = related
        self.capabilities = capabilities
        self.concepts = concepts
        self.localized = localized
        self.powered = powered
    }

    /// Every phrase that names this type: label, synonyms and localized labels.
    public var allNames: [String] {
        [label] + synonyms + localized.keys.sorted().flatMap { localized[$0] ?? [] }
    }
}

public struct BrandEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Lowercase aliases, including the name itself.
    public var aliases: [String]

    public init(id: String, name: String, aliases: [String]) {
        self.id = id
        self.name = name
        self.aliases = aliases
    }
}

public struct RoomEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var aliases: [String]
    public var localized: [String: [String]]
    public var concepts: [String: Double]

    public init(id: String, name: String, aliases: [String], localized: [String: [String]] = [:],
                concepts: [String: Double] = [:]) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.localized = localized
        self.concepts = concepts
    }

    public var allNames: [String] {
        [name] + aliases + localized.keys.sorted().flatMap { localized[$0] ?? [] }
    }
}

public struct StatusPhrase: Codable, Sendable, Hashable {
    public var phrase: String
    public var condition: StatusCondition

    public init(phrase: String, condition: StatusCondition) {
        self.phrase = phrase
        self.condition = condition
    }
}

/// Function words, abbreviations and the meaning lexicon (lexicon.json).
public struct Lexicon: Codable, Sendable, Hashable {
    public var version: Int
    public var statusPhrases: [StatusPhrase]
    public var negations: [String]
    public var quantifiers: [String]
    public var roomPrepositions: [String]
    public var genericNouns: [String]
    public var needWords: [String]
    public var stopWords: [String]
    /// Verbs that start a command ("turn", "dim", …).
    public var actionVerbs: [String]
    /// Verbs that are also device nouns ("switch", "lock"); they start a command only before a strict follower.
    public var strictActionVerbs: [String]
    /// Words that can complete a verb ("on", "off", "up", "down").
    public var actionParticles: [String]
    /// Words allowed right after a strict verb ("on", "the", "all", …).
    public var strictFollowers: [String]
    public var abbreviations: [TextNormalizer.Abbreviation]
    public var protectedStems: [String]
    /// Suffixes for dictionary-validated stripping (decision D16).
    public var suffixes: [String]
    /// Ordered concept dimensions of the meaning lexicon.
    public var conceptDimensions: [String]
    /// Human labels per dimension, used in reason chips ("cool" → "cooling").
    public var conceptLabels: [String: String]
    /// Meaning words (stemmed) → concept weights.
    public var meaningWords: [String: [String: Double]]

    public init(version: Int, statusPhrases: [StatusPhrase], negations: [String], quantifiers: [String],
                roomPrepositions: [String], genericNouns: [String], needWords: [String], stopWords: [String],
                actionVerbs: [String], strictActionVerbs: [String], actionParticles: [String],
                strictFollowers: [String], abbreviations: [TextNormalizer.Abbreviation], protectedStems: [String],
                suffixes: [String], conceptDimensions: [String], conceptLabels: [String: String],
                meaningWords: [String: [String: Double]]) {
        self.version = version
        self.statusPhrases = statusPhrases
        self.negations = negations
        self.quantifiers = quantifiers
        self.roomPrepositions = roomPrepositions
        self.genericNouns = genericNouns
        self.needWords = needWords
        self.stopWords = stopWords
        self.actionVerbs = actionVerbs
        self.strictActionVerbs = strictActionVerbs
        self.actionParticles = actionParticles
        self.strictFollowers = strictFollowers
        self.abbreviations = abbreviations
        self.protectedStems = protectedStems
        self.suffixes = suffixes
        self.conceptDimensions = conceptDimensions
        self.conceptLabels = conceptLabels
        self.meaningWords = meaningWords
    }
}

/// File wrappers matching the JSON resources.
public struct TypesFile: Codable, Sendable { public var version: Int; public var types: [DeviceTypeCard] }
public struct BrandsFile: Codable, Sendable { public var version: Int; public var brands: [BrandEntry] }
public struct RoomsFile: Codable, Sendable { public var version: Int; public var rooms: [RoomEntry] }

/// Typing runs on every keystroke and never calls the model. Submitted runs after Return or a tap on a suggestion.
public enum SearchMode: String, Sendable, Codable {
    case typing, submitted
}

/// Per-search switches.
public struct SearchOptions: Sendable, Equatable {
    /// False for "Search for <raw text> instead": the query is used exactly as typed.
    public var allowCorrections: Bool
    /// Extra typo budget added to every length bucket (zero-result ladder step 2).
    public var typoBudgetBoost: Double
    /// When false, the hybrid phase is skipped (used by system surfaces with tight time limits).
    public var includeMeaning: Bool
    /// When false, the model is never called (system surfaces, tests).
    public var allowRefinement: Bool

    public init(allowCorrections: Bool = true, typoBudgetBoost: Double = 0,
                includeMeaning: Bool = true, allowRefinement: Bool = true) {
        self.allowCorrections = allowCorrections
        self.typoBudgetBoost = typoBudgetBoost
        self.includeMeaning = includeMeaning
        self.allowRefinement = allowRefinement
    }

    public static let standard = SearchOptions()
    /// Fast path for Spotlight, Siri and Shortcuts: lexical only, no model.
    public static let fastPath = SearchOptions(includeMeaning: false, allowRefinement: false)
}

/// Intent classes (design doc §3).
public enum QueryIntent: String, Sendable, Codable, CaseIterable {
    case empty, navigational, categorical, compound, descriptive, command

    /// Categorical, compound and command queries ask for a set of devices.
    public var isSet: Bool {
        switch self {
        case .categorical, .compound, .command: return true
        case .empty, .navigational, .descriptive: return false
        }
    }
}

public enum EntityKind: String, Sendable, Codable, Hashable {
    case type, brand, room, status
}

/// Live-state conditions a query can filter on.
public enum StatusCondition: String, Sendable, Codable, Hashable, CaseIterable {
    case online, offline, on, off

    public var isNetwork: Bool { self == .online || self == .offline }
    public var isPower: Bool { self == .on || self == .off }
}

/// A recognized type, brand, room or status in the query.
public struct QueryEntity: Hashable, Sendable {
    public var kind: EntityKind
    /// Type id, brand id, room id, or a `StatusCondition` raw value.
    public var id: String
    /// Display label, for example "Air Conditioner".
    public var label: String
    /// The user's words that produced the entity, for example "aircon".
    public var words: String
    /// Lowest confidence among the words (corrected words have confidence < 1).
    public var confidence: Double
    /// True when a room preposition ("in", "at") made this room an explicit filter.
    public var isHard: Bool
    /// For rooms: normalized tokens of the room name, used for partial room matches.
    public var roomTokens: [String]

    public init(kind: EntityKind, id: String, label: String, words: String,
                confidence: Double = 1, isHard: Bool = false, roomTokens: [String] = []) {
        self.kind = kind
        self.id = id
        self.label = label
        self.words = words
        self.confidence = confidence
        self.isHard = isHard
        self.roomTokens = roomTokens
    }

    /// Internal BM25F token that only the parser can produce, for example "§t:ac".
    public var specialToken: String? {
        switch kind {
        case .type: return "§t:" + id
        case .brand: return "§b:" + id
        case .room: return "§r:" + id
        case .status: return nil
        }
    }

    public var statusCondition: StatusCondition? { kind == .status ? StatusCondition(rawValue: id) : nil }
}

public enum CorrectionMethod: String, Sendable, Codable, Hashable {
    case edit, phonetic, split, suffix
}

/// One typo correction, shown to the user as "Showing results for …".
public struct Correction: Hashable, Sendable {
    public var from: String
    public var to: String
    public var method: CorrectionMethod
    /// Edit cost for `.edit` corrections, nil otherwise.
    public var cost: Double?
    public var confidence: Double

    public init(from: String, to: String, method: CorrectionMethod, cost: Double? = nil, confidence: Double) {
        self.from = from
        self.to = to
        self.method = method
        self.cost = cost
        self.confidence = confidence
    }
}

/// One query token after classification and correction.
public struct QueryTerm: Hashable, Sendable {
    /// The token as typed (after normalization and stemming).
    public var raw: String
    /// The vocabulary term used for matching (equals `raw` unless corrected).
    public var term: String
    public var confidence: Double
    public var isNumber: Bool
    public var isFunctionWord: Bool
    /// The last token while typing, matched as a prefix.
    public var isPrefix: Bool
    public var isCorrected: Bool
    /// Not in the vocabulary and not correctable.
    public var isUnknown: Bool
    /// A meaning word of a descriptive query, marked once the meaning layer has answered
    /// (`QueryParser.describingNeeds`): it describes the need ("door" in "who is at the door"), so name matching
    /// skips it. Coverage still counts it.
    public var describesNeed: Bool

    public init(raw: String, term: String? = nil, confidence: Double = 1, isNumber: Bool = false,
                isFunctionWord: Bool = false, isPrefix: Bool = false, isCorrected: Bool = false,
                isUnknown: Bool = false, describesNeed: Bool = false) {
        self.raw = raw
        self.term = term ?? raw
        self.confidence = confidence
        self.isNumber = isNumber
        self.isFunctionWord = isFunctionWord
        self.isPrefix = isPrefix
        self.isCorrected = isCorrected
        self.isUnknown = isUnknown
        self.describesNeed = describesNeed
    }
}

public struct QueryFlags: Hashable, Sendable {
    /// "all", "every", …
    public var quantifier = false
    /// A device type written in the plural ("lights").
    public var plural = false
    /// "devices", "things", …
    public var setNoun = false
    /// "in", "at" before a room.
    public var roomPreposition = false
    /// Count of need words ("something", "to", "for", …).
    public var needWords = 0

    public init() {}
}

/// Filters applied as one bitset after fusion. Only populated when the user signalled a set (design doc §5).
public struct HardFilters: Hashable, Sendable {
    public var types: [QueryEntity] = []
    public var brands: [QueryEntity] = []
    public var rooms: [QueryEntity] = []
    public var network: StatusCondition?
    public var power: StatusCondition?
    public var excluded: [QueryEntity] = []

    public init() {}

    public var isEmpty: Bool {
        types.isEmpty && brands.isEmpty && rooms.isEmpty && network == nil && power == nil && excluded.isEmpty
    }
}

/// The result of query understanding (stages S1 and S2).
public struct ParsedQuery: Sendable {
    public var raw: String
    public var mode: SearchMode
    public var normalized: String = ""
    /// Command verb such as "turn off", when the query starts with an action.
    public var action: String?
    /// Normalized tokens after removing the action verb.
    public var tokens: [String] = []
    /// Every token, classified, in order.
    public var terms: [QueryTerm] = []
    public var corrections: [Correction] = []
    public var entities: [QueryEntity] = []
    public var excluded: [QueryEntity] = []
    public var network: StatusCondition?
    public var power: StatusCondition?
    public var flags = QueryFlags()
    /// Terms that are neither function words nor part of an entity phrase.
    public var contentTerms: [QueryTerm] = []
    /// Content terms plus the words of non-negated entities, in query order (function words included).
    public var wordTerms: [QueryTerm] = []
    /// De-duplicated non-function terms (content and non-negated entity words) used for name matching.
    /// Terms marked `describesNeed` are skipped by name matching.
    public var nameTerms: [QueryTerm] = []
    /// Completions of the last token while typing, most frequent first.
    public var completions: [String] = []
    public var lastPrefix: String?
    /// Typed non-function tokens without spaces, for trigram matching ("livingroomtv").
    public var typedKey: String = ""
    /// Typed non-function tokens joined with spaces, for personalization ("bedroom ac").
    public var cleanKey: String = ""
    /// Every term joined with spaces, for exact-name lookup.
    public var sequenceAll: String = ""
    /// Non-function terms joined with spaces, for exact-name lookup.
    public var sequenceContent: String = ""
    /// The query with corrections applied, for "Showing results for …".
    public var correctedText: String = ""
    public var intent: QueryIntent = .empty
    public var intentReason: String = ""
    public var hard = HardFilters()
    /// Terms to highlight in result names.
    public var highlightTerms: Set<String> = []
    /// Content words found in the meaning lexicon.
    public var meaningTermCount: Int = 0

    public init(raw: String, mode: SearchMode) {
        self.raw = raw
        self.mode = mode
    }

    public var hasHardFilters: Bool { !hard.isEmpty }
    public var isEmpty: Bool { intent == .empty }
    public var hasCorrections: Bool { !corrections.isEmpty }
}

/// Result list sections (design doc §9).
public enum ResultSection: String, Sendable, Codable, CaseIterable {
    case best, related, other, set, recent

    public var title: String {
        switch self {
        case .best: return "Best matches"
        case .related: return "Related"
        case .other: return "Other matches"
        case .set: return "Matching devices"
        case .recent: return "Favorites and frequent"
        }
    }
}

public enum ReasonKind: String, Sendable, Codable, Hashable {
    case exactName, typo, soundsLike, split, suffix, type, brand, room, status
    case nameMatch, meaning, closeSpelling, usualPick, favorite, oftenUsed, nickname
}

/// A deterministic explanation shown under a result ("Typo: samsng → samsung"). Never model text.
public struct ReasonChip: Hashable, Sendable {
    public var kind: ReasonKind
    public var text: String

    public init(kind: ReasonKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// A highlighted run inside a device name, as character offsets (0-based, upper bound exclusive).
public struct HighlightRange: Hashable, Sendable {
    public var lowerBound: Int
    public var upperBound: Int

    public init(lowerBound: Int, upperBound: Int) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}

/// One row in the results list.
public struct SearchResult: Identifiable, Hashable, Sendable {
    public var id: DeviceID { device.id }
    public var device: DeviceRecord
    public var typeLabel: String
    /// Two-letter badge, for example "AC".
    public var typeCode: String
    public var section: ResultSection
    /// Display score 0...1.
    public var score: Double
    public var highlights: [HighlightRange]
    public var reasons: [ReasonChip]
    /// Positions moved by the refined phase (positive = up). Zero otherwise.
    public var rankChange: Int
    /// Retrievers that found the device.
    public var evidence: Set<RetrieverID>
    /// Ordinal in the index snapshot that produced the result.
    public var document: Int

    public init(device: DeviceRecord, typeLabel: String, typeCode: String, section: ResultSection,
                score: Double, highlights: [HighlightRange] = [], reasons: [ReasonChip] = [],
                rankChange: Int = 0, evidence: Set<RetrieverID> = [], document: Int) {
        self.device = device
        self.typeLabel = typeLabel
        self.typeCode = typeCode
        self.section = section
        self.score = score
        self.highlights = highlights
        self.reasons = reasons
        self.rankChange = rankChange
        self.evidence = evidence
        self.document = document
    }
}

/// A facet value with a count, shown as a chip on set queries.
public struct FacetChip: Hashable, Sendable {
    public var label: String
    public var count: Int

    public init(label: String, count: Int) {
        self.label = label
        self.count = count
    }
}

/// Header shown for set queries: "31 devices" with type and room chips.
public struct SetSummary: Hashable, Sendable {
    public var count: Int
    public var types: [FacetChip]
    public var rooms: [FacetChip]

    public init(count: Int, types: [FacetChip], rooms: [FacetChip]) {
        self.count = count
        self.types = types
        self.rooms = rooms
    }
}

/// A command query ("turn off hallway lights"): the verb and the resolved targets.
public struct DetectedCommand: Hashable, Sendable {
    public var verb: String
    public var targets: [DeviceID]

    public init(verb: String, targets: [DeviceID]) {
        self.verb = verb
        self.targets = targets
    }
}

/// Progressive result phases (design doc §9).
public enum SearchPhase: String, Sendable, Codable {
    /// Lexical results within one frame.
    case instant
    /// Lexical plus meaning signals.
    case hybrid
    /// Validated model order.
    case refined
    /// The model was wanted but unavailable, late or failed; the hybrid order stands.
    case fallback
}

public enum GateRule: String, Sendable, Codable, CaseIterable {
    case g1ExactName = "G1", g2SetIntent = "G2", g3TooShort = "G3", g4Descriptive = "G4"
    case g5Dominant = "G5", g6NearTie = "G6", g7WeakEvidence = "G7", g8Confident = "G8", g9Available = "G9"
}

public enum GateOutcome: String, Sendable, Codable {
    case skip, rerank, fallback
}

public struct GateStep: Hashable, Sendable {
    public var rule: GateRule
    public var fired: Bool

    public init(rule: GateRule, fired: Bool) {
        self.rule = rule
        self.fired = fired
    }
}

/// The re-rank gate's decision and the rules it evaluated (design doc §7).
public struct GateDecision: Hashable, Sendable {
    public var outcome: GateOutcome
    public var reason: String
    public var path: [GateStep]

    public init(outcome: GateOutcome, reason: String, path: [GateStep]) {
        self.outcome = outcome
        self.reason = reason
        self.path = path
    }
}

/// Timings and decisions for debugging and telemetry. Never shown to users.
public struct SearchDiagnostics: Sendable {
    public var parseDuration: Duration = .zero
    public var retrieveDuration: Duration = .zero
    public var fuseDuration: Duration = .zero
    public var meaningDuration: Duration?
    public var refineDuration: Duration?
    public var candidateCount: Int = 0
    /// Ordinals of the top 20 fused candidates (candidate recall@20 in evaluation).
    public var topCandidates: [Int] = []
    public var gate: GateDecision?
    public var validatorInterventions: [String] = []
    public var snapshotGeneration: UInt64 = 0

    public init() {}
}

/// One emission of the search stream. Each phase replaces the previous list in place.
public struct SearchSnapshot: Sendable {
    public var phase: SearchPhase
    public var query: ParsedQuery
    public var results: [SearchResult]
    public var setSummary: SetSummary?
    /// The corrected query, when any word was corrected.
    public var correctedQuery: String?
    /// The text exactly as typed, for "Search for … instead".
    public var originalQuery: String
    public var relaxed: [RelaxedFilter]
    public var command: DetectedCommand?
    /// True while a model re-rank is running for this query.
    public var isRefining: Bool
    /// Shown above favorites when nothing matched (zero-result ladder step 5).
    public var noMatchesMessage: String?
    public var diagnostics: SearchDiagnostics

    public init(phase: SearchPhase, query: ParsedQuery, results: [SearchResult], setSummary: SetSummary? = nil,
                correctedQuery: String? = nil, originalQuery: String, relaxed: [RelaxedFilter] = [],
                command: DetectedCommand? = nil, isRefining: Bool = false, noMatchesMessage: String? = nil,
                diagnostics: SearchDiagnostics = SearchDiagnostics()) {
        self.phase = phase
        self.query = query
        self.results = results
        self.setSummary = setSummary
        self.correctedQuery = correctedQuery
        self.originalQuery = originalQuery
        self.relaxed = relaxed
        self.command = command
        self.isRefining = isRefining
        self.noMatchesMessage = noMatchesMessage
        self.diagnostics = diagnostics
    }

    public func results(in section: ResultSection) -> [SearchResult] { results.filter { $0.section == section } }

    /// Sections that have rows, in display order.
    public var sections: [ResultSection] {
        ResultSection.allCases.filter { section in results.contains { $0.section == section } }
    }
}

/// The nine retrievers of stage S3. Each produces its own ranked list with evidence.
public enum RetrieverID: String, CaseIterable, Sendable, Codable, Hashable, Comparable {
    case exact, prefix, keywords, trigram, phonetic, facets, semantic, concept, personal

    /// The evidence family used for score breakdowns and reason chips.
    public var family: EvidenceFamily {
        switch self {
        case .exact, .prefix: return .name
        case .keywords: return .keywords
        case .trigram, .phonetic: return .typo
        case .facets: return .filters
        case .semantic, .concept: return .meaning
        case .personal: return .personal
        }
    }

    /// True for retrievers that match the query's text or parsed entities directly.
    /// Used by the nickname learner: a selection with lexical evidence is not a nickname.
    public var isLexical: Bool {
        switch self {
        case .exact, .prefix, .keywords, .trigram, .phonetic, .facets: return true
        case .semantic, .concept, .personal: return false
        }
    }

    public static func < (lhs: RetrieverID, rhs: RetrieverID) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public enum EvidenceFamily: String, CaseIterable, Sendable, Codable {
    case name, keywords, typo, filters, meaning, personal
}

/// One document returned by a retriever. `document` is the ordinal in the current index snapshot.
public struct RetrievalHit: Hashable, Sendable {
    public var document: Int
    public var score: Double

    public init(document: Int, score: Double) {
        self.document = document
        self.score = score
    }
}

/// A retriever's output, best first.
public struct RankedList: Sendable {
    public var retriever: RetrieverID
    public var hits: [RetrievalHit]

    public init(retriever: RetrieverID, hits: [RetrievalHit]) {
        self.retriever = retriever
        self.hits = hits
    }
}

/// A candidate after fusion (stage S4), with the features later stages need.
public struct FusedCandidate: Hashable, Sendable {
    public var document: Int
    /// Weighted RRF contribution per retriever.
    public var contributions: [RetrieverID: Double]
    /// 1-based rank in each retriever's list.
    public var ranks: [RetrieverID: Int]
    /// Sum of contributions.
    public var rrf: Double
    /// Share of query words found in any field (0...1).
    public var coverage: Double
    /// Share of parsed type, brand and room entities the device satisfies (0...1).
    public var entityMatch: Double
    /// Usage, favorite and recency prior (0...1).
    public var prior: Double
    /// rrf + boosts.
    public var score: Double
    /// True when the exact-name retriever found this device.
    public var isExact: Bool
    public var passesHardFilters: Bool

    public init(document: Int) {
        self.document = document
        self.contributions = [:]
        self.ranks = [:]
        self.rrf = 0
        self.coverage = 0
        self.entityMatch = 0
        self.prior = 0
        self.score = 0
        self.isExact = false
        self.passesHardFilters = true
    }

    public func has(_ retriever: RetrieverID) -> Bool { contributions[retriever] != nil }

    /// Retrievers that found this candidate.
    public var evidence: Set<RetrieverID> { Set(contributions.keys) }
}

/// A filter or rule the zero-result ladder relaxed to produce results.
public enum RelaxedFilter: String, Sendable, Codable, Hashable {
    case status, room, brand, type, exclusions, spelling, meaningOnly, rewrite
}

/// The output of fusion: candidates best first.
public struct FusionResult: Sendable {
    public var candidates: [FusedCandidate]
    /// Candidates removed because they failed a hard filter.
    public var removedByFilters: Int
    /// Filters relaxed because nothing matched them all.
    public var relaxed: [RelaxedFilter]

    public init(candidates: [FusedCandidate], removedByFilters: Int = 0, relaxed: [RelaxedFilter] = []) {
        self.candidates = candidates
        self.removedByFilters = removedByFilters
        self.relaxed = relaxed
    }

    public func top(_ count: Int) -> [FusedCandidate] { Array(candidates.prefix(count)) }
}

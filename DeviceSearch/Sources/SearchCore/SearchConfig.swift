/// Every tunable parameter of the search pipeline (design doc §20). Pass a modified copy to experiment;
/// never hard-code these numbers elsewhere.
public struct SearchConfig: Sendable, Equatable {
    // MARK: Fusion (S4)
    /// Reciprocal Rank Fusion constant k.
    public var rrfK: Double = 20
    public var coverageBoost: Double = 0.12
    public var entityMatchBoost: Double = 0.10
    public var priorBoost: Double = 0.04
    /// The prior's weight for descriptive queries: habits should break ties between devices that fit the need,
    /// not lift the much-used Front Door lock above the doorbell for "who is at the door".
    public var descriptivePriorBoost: Double = 0.03
    /// Candidates sent to the gate and the re-ranker (K). Must be 1...20.
    public var candidateCount: Int = 12
    public var fusionWeights: FusionWeights = .standard

    // MARK: Retrieval limits (S3)
    public var prefixLimit: Int = 40
    public var keywordLimit: Int = 60
    public var trigramLimit: Int = 30
    public var phoneticLimit: Int = 30
    public var semanticLimit: Int = 40
    public var conceptLimit: Int = 60
    public var personalLimit: Int = 20
    public var trigramMinDice: Double = 0.30
    public var semanticMinCosine: Double = 0.35
    public var conceptMinSimilarity: Double = 0.45
    /// Routed types must also reach this share of the best type's similarity, so a clear concept
    /// ("who is at the door" → doorbell) is not diluted by its neighbours (locks), which rank fusion would
    /// credit almost as much.
    public var conceptRelativeSimilarity: Double = 0.85
    public var conceptTopTypes: Int = 4
    public var conceptRoomBoost: Double = 0.15

    // MARK: BM25F
    public var bm25K1: Double = 1.2
    public var fields: FieldParameters = .standard
    /// Query weight of a completion of the last word while typing.
    public var completionWeight: Double = 0.7
    public var maxCompletions: Int = 5

    // MARK: Typo correction (S2)
    public var typoBudgets: TypoBudgets = .standard
    /// Added to every budget by the zero-result ladder (step 2).
    public var typoBudgetBoost: Double = 0.5
    /// confidence = 1 - correctionCostWeight x cost.
    public var correctionCostWeight: Double = 0.3
    public var phoneticConfidence: Double = 0.6
    public var splitConfidence: Double = 0.9
    public var suffixConfidence: Double = 0.9
    /// Corrections below this confidence never become hard filters.
    public var minConfidenceForHardFilter: Double = 0.5
    /// The exact retriever ignores queries with a correction below this confidence.
    public var minConfidenceForExact: Double = 0.6
    /// Tokens at least this long are tried as two glued words.
    public var compoundSplitMinLength: Int = 6
    /// Longest phrase looked up in the phrase dictionary, in words.
    public var maxPhraseLength: Int = 4

    // MARK: Gate (S5)
    public var gateMinCharacters: Int = 3
    public var gateDominanceMargin: Double = 0.25
    public var gateNearTieBand: Double = 0.10

    // MARK: Re-rank (S6)
    public var rerankDeadline: Duration = .seconds(2)
    public var maxBest: Int = 8
    public var maxRelated: Int = 6
    public var maxResponseTokens: Int = 64
    public var nameCharacterLimit: Int = 40

    // MARK: Validator (S7)
    public var blendLambdaDescriptive: Double = 0.65
    public var blendLambdaOther: Double = 0.45
    public var displayThreshold: Double = 0.15
    public var bestPositionStep: Double = 0.06
    public var relatedBase: Double = 0.45
    public var relatedPositionStep: Double = 0.04
    public var recoveredScore: Double = 0.30

    // MARK: Presentation (S8)
    /// Hybrid rows with normalized score at or above this go to "Best matches".
    public var bestThreshold: Double = 0.55
    /// Hybrid rows with normalized score at or above this go to "Related".
    public var relatedThreshold: Double = 0.20
    public var maxBestRows: Int = 8
    public var maxRelatedRows: Int = 10
    public var emptyStateCount: Int = 8

    // MARK: Timing
    /// Idle time after the last keystroke before meaning signals run.
    public var semanticIdleDelay: Duration = .milliseconds(120)
    /// Device events are coalesced for this long before the index rebuilds.
    public var rebuildCoalescing: Duration = .milliseconds(250)

    // MARK: Personalization (§15)
    public var affinityHalfLifeDays: Double = 21
    public var usageHalfLifeDays: Double = 30
    public var failureRetentionDays: Double = 30
    public var reformulationWindow: Duration = .seconds(5)
    public var settleDelay: Duration = .seconds(1)
    public var nicknameThreshold: Int = 3
    /// Learned nicknames are indexed like names at this fraction of the name field weight.
    public var nicknameWeight: Double = 0.8
    public var minAffinityPrefixLength: Int = 2
    public var favoriteAffinity: Double = 0.5

    public init() {}

    public static let `default` = SearchConfig()

    /// Validates ranges. Call once at startup; a violation is a programming error.
    public func validated() -> SearchConfig {
        precondition((1...20).contains(candidateCount), "candidateCount must be 1...20")
        precondition(rrfK > 0, "rrfK must be positive")
        return self
    }

    /// The fusion weights for a query intent.
    public func weights(for intent: QueryIntent) -> [RetrieverID: Double] {
        switch intent {
        case .descriptive: return fusionWeights.descriptive
        case .categorical, .compound, .command: return fusionWeights.set
        case .navigational, .empty: return fusionWeights.navigational
        }
    }

    /// Blend weight λ of the model score (S7).
    public func blendLambda(for intent: QueryIntent) -> Double {
        intent == .descriptive ? blendLambdaDescriptive : blendLambdaOther
    }
}

/// Retriever weights per intent group (design doc §7).
public struct FusionWeights: Sendable, Equatable {
    public var navigational: [RetrieverID: Double]
    public var descriptive: [RetrieverID: Double]
    public var set: [RetrieverID: Double]

    public init(navigational: [RetrieverID: Double], descriptive: [RetrieverID: Double], set: [RetrieverID: Double]) {
        self.navigational = navigational
        self.descriptive = descriptive
        self.set = set
    }

    public static let standard = FusionWeights(
        navigational: [.exact: 3.0, .prefix: 1.5, .keywords: 1.6, .trigram: 1.0, .phonetic: 0.6,
                       .facets: 0.8, .semantic: 0.5, .concept: 0.4, .personal: 0.6],
        descriptive: [.exact: 1.0, .prefix: 0.4, .keywords: 0.8, .trigram: 0.4, .phonetic: 0.2,
                      .facets: 1.0, .semantic: 1.6, .concept: 1.4, .personal: 0.5],
        set: [.exact: 1.0, .prefix: 0.6, .keywords: 1.0, .trigram: 0.6, .phonetic: 0.4,
              .facets: 2.0, .semantic: 0.4, .concept: 0.4, .personal: 0.8]
    )
}

/// BM25F weight w and length normalization b of one field.
public struct FieldParameter: Sendable, Equatable {
    public var weight: Double
    public var lengthNormalization: Double

    public init(weight: Double, lengthNormalization: Double) {
        self.weight = weight
        self.lengthNormalization = lengthNormalization
    }
}

/// BM25F parameters per field (design doc §6). The alias field holds learned nicknames.
public struct FieldParameters: Sendable, Equatable {
    public var name: FieldParameter
    public var alias: FieldParameter
    public var type: FieldParameter
    public var brand: FieldParameter
    public var room: FieldParameter

    public init(name: FieldParameter, alias: FieldParameter, type: FieldParameter,
                brand: FieldParameter, room: FieldParameter) {
        self.name = name
        self.alias = alias
        self.type = type
        self.brand = brand
        self.room = room
    }

    public static let standard = FieldParameters(
        name: FieldParameter(weight: 3.0, lengthNormalization: 0.75),
        alias: FieldParameter(weight: 2.4, lengthNormalization: 0.75),
        type: FieldParameter(weight: 2.0, lengthNormalization: 0.30),
        brand: FieldParameter(weight: 1.6, lengthNormalization: 0.30),
        room: FieldParameter(weight: 1.6, lengthNormalization: 0.50)
    )
}

/// Maximum typo cost by token length (design doc §5).
public struct TypoBudgets: Sendable, Equatable {
    public var upTo3: Double
    public var upTo5: Double
    public var upTo8: Double
    public var longer: Double

    public init(upTo3: Double, upTo5: Double, upTo8: Double, longer: Double) {
        self.upTo3 = upTo3
        self.upTo5 = upTo5
        self.upTo8 = upTo8
        self.longer = longer
    }

    public static let standard = TypoBudgets(upTo3: 0.5, upTo5: 1.0, upTo8: 1.5, longer: 2.0)

    public func maxCost(forLength length: Int) -> Double {
        switch length {
        case ...3: return upTo3
        case 4...5: return upTo5
        case 6...8: return upTo8
        default: return longer
        }
    }
}

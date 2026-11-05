import Foundation
import SearchCore
import SearchIndex
import SearchRanking

// Extension points (decision D05). Milestones 2–4 add modules that implement these protocols;
// the engine never changes. Every plug-in is optional: with none, search is purely lexical.

/// Meaning signals for milestone 2: semantic and concept retrievers over embeddings.
public protocol MeaningRetrieval: Sendable {
    /// Semantic and concept ranked lists for a query, plus a human label of its meaning ("cooling").
    /// Return nil when meaning is unavailable (no vectors yet, unsupported language).
    func meaningLists(for query: ParsedQuery, in snapshot: IndexSnapshot, config: SearchConfig) async -> MeaningOutput?

    /// Cached embeddings for index builds, so a rebuild starts warm.
    var vectorSource: (any VectorSource)? { get }

    /// Called after every snapshot swap. Embed what is missing in the background and report new vectors to `sink`.
    func snapshotDidChange(_ snapshot: IndexSnapshot, sink: any VectorUpdateSink) async
}

public struct MeaningOutput: Sendable {
    public var lists: [RankedList]
    public var label: String?

    public init(lists: [RankedList], label: String?) {
        self.lists = lists
        self.label = label
    }
}

/// Receives freshly embedded vectors for a snapshot generation.
public protocol VectorUpdateSink: Sendable {
    func applyVectors(_ vectors: VectorStore, concepts: ConceptVectors, generation: UInt64) async
}

/// Re-ranking for milestone 3: build the prompt, call the model, validate, present.
public protocol ResultRefining: Sendable {
    /// Model available, enabled in Settings, not in Low Power Mode, thermal state below serious (gate rule G9).
    func isAvailable() async -> Bool
    /// Loads model resources ahead of a request. Called when the search field gains focus.
    func prewarm() async
    /// Must return validated rows. Throw on any model error; the engine keeps the fused order.
    func refine(_ request: RefinementRequest) async throws -> RefinementOutcome
    /// Streaming variant (L08, optional): call `partial` with validated top rows as soon as the model has
    /// emitted its `best` array, then return the final outcome. The default implementation never calls `partial`.
    func refine(_ request: RefinementRequest,
                partial: @escaping @Sendable ([SearchResult]) async -> Void) async throws -> RefinementOutcome
}

extension ResultRefining {
    public func refine(_ request: RefinementRequest,
                       partial: @escaping @Sendable ([SearchResult]) async -> Void) async throws -> RefinementOutcome {
        try await refine(request)
    }
}

public struct RefinementRequest: Sendable {
    public var query: ParsedQuery
    /// The top K fused candidates, in fused order.
    public var candidates: [FusedCandidate]
    public var snapshot: IndexSnapshot
    public var context: PresentationContext
    public var config: SearchConfig

    public init(query: ParsedQuery, candidates: [FusedCandidate], snapshot: IndexSnapshot,
                context: PresentationContext, config: SearchConfig) {
        self.query = query
        self.candidates = candidates
        self.snapshot = snapshot
        self.context = context
        self.config = config
    }
}

public struct RefinementOutcome: Sendable {
    public var results: [SearchResult]
    /// Validator rules that changed the model's answer, for example ["V1", "V4"].
    public var interventions: [String]
    /// Agreement between fused and final order.
    public var kendallTau: Double?

    public init(results: [SearchResult], interventions: [String], kendallTau: Double?) {
        self.results = results
        self.interventions = interventions
        self.kendallTau = kendallTau
    }
}

/// A classified refinement failure, so telemetry can count timeouts, guardrails and context overflows.
public struct RefinementFailure: Error, Sendable, Equatable {
    public var outcome: RerankOutcome

    public init(_ outcome: RerankOutcome) {
        self.outcome = outcome
    }
}

/// Zero-result ladder step 4 (milestone 3): one model rewrite of a query that matched nothing.
public protocol QueryRewriting: Sendable {
    /// A replacement query made of known type names and vocabulary words, or nil.
    func rewrite(_ query: ParsedQuery, in snapshot: IndexSnapshot) async throws -> String?
}

/// Personal signals for milestone 4.
public protocol PersonalSignals: Sendable {
    /// The personal ranked list: devices picked before for this query, plus favorites in `pool`.
    /// `reasons` says, per ordinal, whether it is the user's usual pick or a favorite.
    func personalList(for query: ParsedQuery, pool: Set<Int>, in snapshot: IndexSnapshot,
                      config: SearchConfig) async -> (list: RankedList, reasons: [Int: ReasonKind])?
    /// Priors and learned nicknames for the next index build.
    func indexInputs(for devices: [DeviceRecord]) async -> PersonalIndexInputs
    /// Returns what changed, so the engine can refresh priors in place or ask for a rebuild (new nickname).
    func recordSelection(_ selection: SelectionRecord) async -> PersonalChange
    /// A query the user stopped typing or submitted (reformulation detection).
    func recordSettledQuery(_ text: String, at date: Date) async
    /// The device was opened or controlled.
    func recordUsage(of device: DeviceID, at date: Date) async -> PersonalChange
}

/// What a personal signal changed.
public struct PersonalChange: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Usage priors moved: the engine updates them in place (no rebuild).
    public static let priors = PersonalChange(rawValue: 1 << 0)
    /// A nickname was learned or removed: the index must rebuild to include it.
    public static let aliases = PersonalChange(rawValue: 1 << 1)
}

public struct PersonalIndexInputs: Sendable {
    public var priors: [DeviceID: Double]?
    public var aliases: [DeviceID: [String]]

    public init(priors: [DeviceID: Double]? = nil, aliases: [DeviceID: [String]] = [:]) {
        self.priors = priors
        self.aliases = aliases
    }
}

/// A result the user chose.
public struct SelectionRecord: Sendable, Equatable {
    /// The query as typed, normalized without function words ("bedroom ac").
    public var queryKey: String
    public var device: DeviceID
    /// 1-based position in the list.
    public var position: Int
    /// True when exact, prefix, keyword, trigram, phonetic or facet evidence connected the query to the device.
    public var hadLexicalEvidence: Bool
    public var date: Date

    public init(queryKey: String, device: DeviceID, position: Int, hadLexicalEvidence: Bool, date: Date) {
        self.queryKey = queryKey
        self.device = device
        self.position = position
        self.hadLexicalEvidence = hadLexicalEvidence
        self.date = date
    }
}

/// Adapts `PersonalIndexInputs` to the index builder's provider protocols.
struct StaticPriors: PriorProviding {
    let values: [DeviceID: Double]
    func priors(for devices: [DeviceRecord]) -> [DeviceID: Double] { values }
}

struct StaticAliases: AliasProviding {
    let values: [DeviceID: [String]]
    func aliases(for device: DeviceID) -> [String] { values[device] ?? [] }
}

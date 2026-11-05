import Synchronization

/// How a re-rank attempt ended.
public enum RerankOutcome: String, Sendable, Codable {
    case refined, timeout, unavailable, contextWindow, guardrail, unsupportedLanguage, cancelled, failed
}

/// Per-search metrics. Contains no query text and no device names (design doc §16).
public struct SearchMetrics: Sendable, Equatable {
    public var intent: QueryIntent
    public var mode: SearchMode
    public var phase: SearchPhase
    public var resultCount: Int
    public var gate: GateOutcome?
    public var instantDuration: Duration
    public var hybridDuration: Duration?

    public init(intent: QueryIntent, mode: SearchMode, phase: SearchPhase, resultCount: Int,
                gate: GateOutcome?, instantDuration: Duration, hybridDuration: Duration? = nil) {
        self.intent = intent
        self.mode = mode
        self.phase = phase
        self.resultCount = resultCount
        self.gate = gate
        self.instantDuration = instantDuration
        self.hybridDuration = hybridDuration
    }
}

public struct RerankMetrics: Sendable, Equatable {
    public var outcome: RerankOutcome
    public var latency: Duration
    /// Validator rules that changed the model's answer, for example ["V1", "V4"].
    public var interventions: [String]
    /// Agreement between fused and final order (-1...1), nil when not refined.
    public var kendallTau: Double?

    public init(outcome: RerankOutcome, latency: Duration, interventions: [String] = [], kendallTau: Double? = nil) {
        self.outcome = outcome
        self.latency = latency
        self.interventions = interventions
        self.kendallTau = kendallTau
    }
}

public enum SearchTelemetryEvent: Sendable, Equatable {
    case searchCompleted(SearchMetrics)
    case rerank(RerankMetrics)
    case indexRebuilt(documents: Int, duration: Duration)
    case embeddingsUpdated(count: Int, duration: Duration)
    case selection(position: Int, section: ResultSection)
    case reformulationMiss
    case nicknameLearned
}

/// Receives telemetry. Implementations must not block and must never upload query text or device names.
public protocol SearchTelemetry: Sendable {
    func record(_ event: SearchTelemetryEvent)
}

public struct NoopTelemetry: SearchTelemetry {
    public init() {}
    public func record(_ event: SearchTelemetryEvent) {}
}

/// Keeps events in memory and derives the rates the design doc monitors.
/// Use in tests and a debug screen.
public final class InMemoryTelemetry: SearchTelemetry {
    private let storage = Mutex<[SearchTelemetryEvent]>([])

    public init() {}

    public func record(_ event: SearchTelemetryEvent) {
        storage.withLock { $0.append(event) }
    }

    public var events: [SearchTelemetryEvent] { storage.withLock { $0 } }

    public func reset() { storage.withLock { $0.removeAll() } }

    /// Share of submitted searches the gate sent to the model (target 15–30%, alarm above 40%).
    public var modelInvocationRate: Double {
        let submitted = events.compactMap { event -> SearchMetrics? in
            if case .searchCompleted(let metrics) = event, metrics.mode == .submitted { return metrics }
            return nil
        }
        guard !submitted.isEmpty else { return 0 }
        return Double(submitted.filter { $0.gate == .rerank }.count) / Double(submitted.count)
    }

    /// Share of re-ranks where the validator changed the model's answer (alarm above 5%).
    public var interventionRate: Double {
        let reranks = events.compactMap { event -> RerankMetrics? in
            if case .rerank(let metrics) = event, metrics.outcome == .refined { return metrics }
            return nil
        }
        guard !reranks.isEmpty else { return 0 }
        return Double(reranks.filter { !$0.interventions.isEmpty }.count) / Double(reranks.count)
    }

    /// Share of searches (any mode) that returned nothing.
    public var zeroResultRate: Double {
        let searches = events.compactMap { event -> SearchMetrics? in
            if case .searchCompleted(let metrics) = event { return metrics }
            return nil
        }
        guard !searches.isEmpty else { return 0 }
        return Double(searches.filter { $0.resultCount == 0 }.count) / Double(searches.count)
    }
}

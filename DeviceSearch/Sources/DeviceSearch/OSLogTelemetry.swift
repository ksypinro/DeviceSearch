#if canImport(OSLog)
import OSLog
import SearchCore

/// Telemetry in the unified log (design doc §16, decision D12): outcomes, counts and durations only —
/// never query text or device names. Stream it with
/// `log stream --level info --predicate 'subsystem == "com.example.home"'`.
public struct OSLogTelemetry: SearchTelemetry {
    private let logger: Logger

    public init(subsystem: String, category: String = "DeviceSearch") {
        logger = Logger(subsystem: subsystem, category: category)
    }

    public func record(_ event: SearchTelemetryEvent) {
        switch event {
        case .searchCompleted(let m):
            let gate = m.gate?.rawValue ?? "none"
            let instant = Self.milliseconds(m.instantDuration)
            logger.info("search intent=\(m.intent.rawValue, privacy: .public) mode=\(m.mode.rawValue, privacy: .public) phase=\(m.phase.rawValue, privacy: .public) results=\(m.resultCount, privacy: .public) gate=\(gate, privacy: .public) instant_ms=\(instant, privacy: .public)")
        case .rerank(let m):
            let rules = m.interventions.joined(separator: ",")
            let latency = Self.milliseconds(m.latency)
            let tau = m.kendallTau ?? 1
            logger.info("rerank outcome=\(m.outcome.rawValue, privacy: .public) ms=\(latency, privacy: .public) interventions=\(rules, privacy: .public) tau=\(tau, privacy: .public)")
        case .indexRebuilt(let documents, let duration):
            let ms = Self.milliseconds(duration)
            logger.info("index rebuilt documents=\(documents, privacy: .public) ms=\(ms, privacy: .public)")
        case .embeddingsUpdated(let count, let duration):
            let ms = Self.milliseconds(duration)
            logger.info("embeddings updated count=\(count, privacy: .public) ms=\(ms, privacy: .public)")
        case .selection(let position, let section):
            logger.info("selection position=\(position, privacy: .public) section=\(section.rawValue, privacy: .public)")
        case .reformulationMiss:
            logger.info("reformulation miss")
        case .nicknameLearned:
            logger.info("nickname learned")
        }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}
#endif

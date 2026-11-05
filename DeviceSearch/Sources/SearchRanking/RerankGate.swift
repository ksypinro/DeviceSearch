import SearchCore

/// Stage S5 (design doc §7): can the model improve this order enough to be worth about a second?
/// Rules run in order and the first decisive one wins. Only called for submitted searches (decision D13).
public struct RerankGate: Sendable {
    public let config: SearchConfig

    public init(config: SearchConfig = .default) {
        self.config = config
    }

    public func decide(query: ParsedQuery, fusion: FusionResult, modelAvailable: Bool) -> GateDecision {
        let top = fusion.top(config.candidateCount)
        var path: [GateStep] = []
        func step(_ rule: GateRule, _ fired: Bool) -> Bool {
            path.append(GateStep(rule: rule, fired: fired))
            return fired
        }
        func skip(_ reason: String) -> GateDecision { GateDecision(outcome: .skip, reason: reason, path: path) }

        guard !top.isEmpty else { return skip("Nothing to rank") }
        let s1 = top[0].score
        let s2 = top.count > 1 ? top[1].score : 0

        if step(.g1ExactName, top[0].isExact) { return skip("Exact name match, pinned first") }
        if step(.g2SetIntent, query.intent.isSet) { return skip("Set query: the filtered set is the answer") }
        if step(.g3TooShort, query.normalized.filter { $0 != " " }.count < config.gateMinCharacters) {
            return skip("Too short: type-ahead only")
        }

        let wanted: String
        if step(.g4Descriptive, query.intent == .descriptive) {
            wanted = "Descriptive intent"
        } else {
            let dominant = top.count == 1
                || (s1 > 0 && (s1 - s2) / s1 >= config.gateDominanceMargin && top[0].coverage >= 0.99)
            if step(.g5Dominant, dominant) { return skip("Top result is dominant") }
            let ties = top.filter { $0.score >= (1 - config.gateNearTieBand) * s1 }.count
            if step(.g6NearTie, top.count > 1 && ties >= 2) {
                wanted = "\(ties) candidates within \(Int(config.gateNearTieBand * 100))% of the top"
            } else {
                let weak = top.prefix(3).allSatisfy { candidate in
                    !candidate.has(.exact) && !candidate.has(.prefix)
                        && !(candidate.has(.keywords) && candidate.coverage > 0)
                        && !(candidate.has(.facets) && candidate.entityMatch > 0)
                }
                if step(.g7WeakEvidence, weak) {
                    wanted = "Top results rest on typo, meaning or personal signals only"
                } else {
                    _ = step(.g8Confident, true)
                    return skip("Confident without the model")
                }
            }
        }
        if step(.g9Available, modelAvailable) {
            return GateDecision(outcome: .rerank, reason: wanted, path: path)
        }
        return GateDecision(outcome: .fallback, reason: wanted + "; the model is unavailable, so the fused order stays",
                            path: path)
    }
}

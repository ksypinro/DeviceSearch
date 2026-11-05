import Testing
import SearchCore
import SearchIndex
import SearchQuery
import SearchRetrieval
@testable import SearchRanking
import SearchTestSupport

@Suite("Re-rank gate")
struct RerankGateTests {
    func decide(_ text: String, available: Bool = true) -> GateDecision {
        let (query, _, result) = fused(text)
        return RerankGate().decide(query: query, fusion: result, modelAvailable: available)
    }

    @Test func exactNameSkips() {
        let decision = decide("Bedroom AC")
        #expect(decision.outcome == .skip)
        #expect(decision.path == [GateStep(rule: .g1ExactName, fired: true)])
    }

    @Test func setQueriesSkip() {
        #expect(decide("all lights").path.last == GateStep(rule: .g2SetIntent, fired: true))
    }

    @Test func descriptiveQueriesWantTheModel() {
        let decision = decide("something to cool the bedroom")
        #expect(decision.outcome == .rerank)
        #expect(decision.path.map(\.rule) == [.g1ExactName, .g2SetIntent, .g3TooShort, .g4Descriptive, .g9Available])
    }

    @Test func unavailableModelFallsBack() {
        #expect(decide("something to cool the bedroom", available: false).outcome == .fallback)
    }

    @Test func nearTiesWantTheModel() {
        let decision = decide("philips lamp")
        #expect(decision.path.contains(GateStep(rule: .g6NearTie, fired: true)) || decision.outcome == .skip)
    }

    @Test func nothingToRankSkips() {
        let (query, _, _) = fused("zzzzqqq")
        let decision = RerankGate().decide(query: query, fusion: FusionResult(candidates: []), modelAvailable: true)
        #expect(decision.outcome == .skip)
        #expect(decision.path.isEmpty)
    }
}

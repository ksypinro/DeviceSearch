import Testing
@testable import SearchCore

@Suite("Configuration and flags")
struct ConfigAndFlagsTests {
    @Test func defaultsMatchDesignDocAppendix() {
        let config = SearchConfig.default
        #expect(config.rrfK == 20)
        #expect(config.candidateCount == 12)
        #expect(config.maxBest == 8 && config.maxRelated == 6)
        #expect(config.rerankDeadline == .seconds(2))
        #expect(config.semanticIdleDelay == .milliseconds(120))
        #expect(config.semanticMinCosine == 0.35)
        #expect(config.conceptMinSimilarity == 0.45)
        #expect(config.trigramMinDice == 0.30)
        #expect(config.gateDominanceMargin == 0.25 && config.gateNearTieBand == 0.10)
        #expect(config.blendLambdaDescriptive == 0.65 && config.blendLambdaOther == 0.45)
        #expect(config.displayThreshold == 0.15)
        #expect(config.rebuildCoalescing == .milliseconds(250))
        #expect(config.affinityHalfLifeDays == 21)
        #expect(config.nicknameThreshold == 3)
        #expect(config.typoBudgets.maxCost(forLength: 3) == 0.5)
        #expect(config.typoBudgets.maxCost(forLength: 5) == 1.0)
        #expect(config.typoBudgets.maxCost(forLength: 8) == 1.5)
        #expect(config.typoBudgets.maxCost(forLength: 9) == 2.0)
    }

    @Test func weightsFollowIntent() {
        let config = SearchConfig.default
        #expect(config.weights(for: .navigational)[.exact] == 3.0)
        #expect(config.weights(for: .descriptive)[.semantic] == 1.6)
        #expect(config.weights(for: .compound)[.facets] == 2.0)
        #expect(config.blendLambda(for: .descriptive) == 0.65)
    }

    @Test func flagStoreActsAsKillSwitch() {
        let store = FeatureFlagStore(.allOn)
        #expect(store.currentFlags().rerankEnabled)
        store.update { $0.rerankEnabled = false }
        #expect(!store.currentFlags().rerankEnabled)
    }

    @Test func telemetryRates() {
        let telemetry = InMemoryTelemetry()
        telemetry.record(.searchCompleted(SearchMetrics(intent: .descriptive, mode: .submitted, phase: .refined,
                                                        resultCount: 3, gate: .rerank, instantDuration: .milliseconds(2))))
        telemetry.record(.searchCompleted(SearchMetrics(intent: .navigational, mode: .submitted, phase: .hybrid,
                                                        resultCount: 0, gate: .skip, instantDuration: .milliseconds(2))))
        telemetry.record(.rerank(RerankMetrics(outcome: .refined, latency: .seconds(1), interventions: ["V4"])))
        #expect(telemetry.modelInvocationRate == 0.5)
        #expect(telemetry.interventionRate == 1.0)
        #expect(telemetry.zeroResultRate == 0.5)
    }
}

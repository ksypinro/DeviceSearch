import Foundation
import Testing
import SearchCore
import SearchIndex
@testable import DeviceSearch
import SearchTestSupport

@Suite("Search engine")
struct SearchEngineTests {
    func engine(meaning: (any MeaningRetrieval)? = nil, refiner: (any ResultRefining)? = nil,
                config: SearchConfig = .default, snapshot: IndexSnapshot = TestIndex.home500,
                telemetry: any SearchTelemetry = NoopTelemetry()) -> SearchEngine {
        SearchEngine(snapshot: snapshot, config: config, telemetry: telemetry, meaning: meaning, refiner: refiner)
    }

    @Test func typingYieldsOneInstantSnapshotWithoutPlugins() async {
        let phases = await engine().searchAll("bedroom ac", mode: .typing)
        #expect(phases.map(\.phase) == [.instant])
        #expect(phases[0].results.first?.device.name == "Bedroom AC")
        #expect(phases[0].diagnostics.gate == nil)   // the gate never runs while typing
    }

    @Test func emptyQueryShowsFavorites() async {
        let phases = await engine().searchAll("  ", mode: .typing)
        #expect(phases.count == 1)
        #expect(phases[0].results.allSatisfy { $0.section == .recent })
    }

    @Test func meaningAddsAHybridPhase() async {
        let phases = await engine(meaning: FakeMeaning()).searchAll("something to cool the bedroom", mode: .submitted)
        #expect(phases.map(\.phase) == [.instant, .hybrid])
        #expect(phases[1].results.first.map { ["ac", "fan"].contains(TestIndex.home500.document(for: $0.id)!.typeID) } == true)
        #expect(phases[1].results.first?.reasons.contains { $0.text == "Meaning: cooling" } == true)
    }

    @Test func refinedPhaseFollowsTheGate() async {
        let refiner = FakeRefiner()
        let telemetry = InMemoryTelemetry()
        let phases = await engine(meaning: FakeMeaning(), refiner: refiner, telemetry: telemetry)
            .searchAll("something to cool the bedroom", mode: .submitted)
        #expect(phases.map(\.phase) == [.instant, .hybrid, .refined])
        #expect(phases[1].isRefining)
        #expect(!phases[2].isRefining)
        #expect(phases[2].results.count == 12)              // K candidates
        #expect(telemetry.modelInvocationRate == 1)
    }

    @Test func streamingYieldsAPartialRefinedSnapshotOnlyWhenFlagged() async {
        let flags = FeatureFlagStore(.allOn)
        let streamed = SearchEngine(snapshot: TestIndex.home500, flags: flags, refiner: StreamingFakeRefiner())
        let off = await streamed.searchAll("something to cool the bedroom", mode: .submitted)
        #expect(off.map(\.phase) == [.instant, .refined])
        flags.update { $0.streamingRerankEnabled = true }
        let on = await streamed.searchAll("something to cool the bedroom", mode: .submitted)
        #expect(on.map(\.phase) == [.instant, .refined, .refined])
        #expect(on[1].isRefining && on[1].results.count == 1)
        #expect(!on[2].isRefining && on[2].results.count == 12)
    }

    @Test func exactNamesNeverCallTheModel() async {
        let phases = await engine(refiner: FakeRefiner()).searchAll("Bedroom AC", mode: .submitted)
        #expect(phases.map(\.phase) == [.instant])
        #expect(phases[0].diagnostics.gate?.outcome == .skip)
    }

    @Test func slowModelFallsBackAtTheDeadline() async {
        var config = SearchConfig.default
        config.rerankDeadline = .milliseconds(50)
        let telemetry = InMemoryTelemetry()
        let phases = await engine(refiner: FakeRefiner(delay: .seconds(5)), config: config, telemetry: telemetry)
            .searchAll("something to cool the bedroom", mode: .submitted)
        #expect(phases.last?.phase == .fallback)
        #expect(phases.last?.results.map(\.id) == phases.first?.results.map(\.id))
        #expect(telemetry.events.contains { if case .rerank(let m) = $0 { return m.outcome == .timeout }; return false })
    }

    @Test func modelErrorsFallBackSilently() async {
        let refiner = FakeRefiner(failure: RefinementFailure(.guardrail))
        let phases = await engine(refiner: refiner).searchAll("something to cool the bedroom", mode: .submitted)
        #expect(phases.last?.phase == .fallback)
    }

    @Test func unavailableModelYieldsFallback() async {
        let phases = await engine(refiner: FakeRefiner(available: false)).searchAll("something to cool the bedroom", mode: .submitted)
        #expect(phases.map(\.phase) == [.instant, .fallback])
        #expect(phases[0].isRefining == false)
    }

    @Test func gateIsRecordedEvenWithoutAModel() async {
        let phases = await engine().searchAll("something to cool the bedroom", mode: .submitted)
        #expect(phases.map(\.phase) == [.instant])
        #expect(phases[0].diagnostics.gate?.outcome == .fallback)   // wanted, but no model is installed
    }

    @Test func droppingTheStreamCancelsTheSearch() async {
        let meaning = FakeMeaning(delay: .milliseconds(300))
        let engine = engine(meaning: meaning)
        var received = 0
        for await _ in engine.search("something to cool", mode: .typing) {
            received += 1
            break   // the next keystroke arrives
        }
        try? await Task.sleep(for: .milliseconds(500))
        #expect(received == 1)
        #expect(meaning.calls.count <= 1)
    }

    @Test func correctionsAreShownWithTheOriginal() async {
        let snapshot = await engine().searchAll("samsng tv", mode: .submitted).last!
        #expect(snapshot.correctedQuery == "samsung tv")
        #expect(snapshot.originalQuery == "samsng tv")
        let raw = await engine().searchAll("samsng tv", mode: .submitted,
                                           options: SearchOptions(allowCorrections: false)).last!
        #expect(raw.correctedQuery == nil)
    }

    @Test func setQueriesCarryASummaryAndCommandsTheirTargets() async {
        let set = await engine().searchAll("offline cameras", mode: .submitted).last!
        #expect(set.setSummary?.count == set.results.count)
        let command = await engine().searchAll("turn off hallway lights", mode: .submitted).last!
        #expect(command.command?.verb == "turn off")
        #expect(command.command?.targets.count == command.results.count)
    }

    @Test func prewarmReachesTheRefiner() async {
        let refiner = FakeRefiner()
        await engine(refiner: refiner).prewarm()
        #expect(refiner.prewarms.count == 1)
    }
}

@Suite("Zero-result ladder")
struct ZeroResultLadderTests {
    @Test func relaxesFiltersFirst() async {
        let snapshot = await SearchEngine(snapshot: TestIndex.home500).searchAll("samsung lights", mode: .submitted).last!
        #expect(snapshot.relaxed == [.brand])
        #expect(!snapshot.results.isEmpty)
        #expect(snapshot.noMatchesMessage == nil)
    }

    @Test func raisesTypoToleranceSecond() async {
        var config = SearchConfig.default
        config.typoBudgets = TypoBudgets(upTo3: 0, upTo5: 0, upTo8: 0, longer: 0)
        config.typoBudgetBoost = 1.0
        config.trigramMinDice = 1.1     // disable trigrams so only the corrected word can match
        let engine = SearchEngine(snapshot: TestIndex.tiny, config: config)
        let snapshot = await engine.searchAll("bedrooj", mode: .submitted).last!
        #expect(snapshot.relaxed.contains(.spelling))
        #expect(snapshot.results.first?.device.name == "Bedroom AC")
    }

    @Test func endsWithFavoritesAndAMessage() async {
        let snapshot = await SearchEngine(snapshot: TestIndex.home500).searchAll("zzqqxx", mode: .submitted).last!
        #expect(snapshot.noMatchesMessage == "No devices match “zzqqxx”")
        #expect(snapshot.results.allSatisfy { $0.section == .recent })
        #expect(snapshot.command == nil)
    }
}

@Suite("System surfaces")
struct SystemSurfaceTests {
    @Test func fastPathUsesLexicalResultsOnly() async {
        let engine = SearchEngine(snapshot: TestIndex.home500, refiner: FakeRefiner())
        let results = await engine.topResults(for: "bedrom ac", limit: 3)
        #expect(results.first?.device.name == "Bedroom AC")
        #expect(await engine.favoritesAndRecents(limit: 4).count == 4)
        #expect(await engine.devices(withIDs: ["d001", "nope"]).map(\.name) == ["Bedroom AC"])
    }
}

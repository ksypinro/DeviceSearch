import Foundation
import Synchronization
import Testing
import SearchCore
import SearchIndex
import SearchRanking
import DeviceSearch
@testable import DeviceSearchUI
import SearchTestSupport

@MainActor
@Suite("Search view model")
struct SearchViewModelTests {
    func makeModel(refiner: (any ResultRefining)? = SlowRefiner(), voice: (any VoiceTranscribing)? = nil,
                   coordinator: CoordinatorSpy? = nil) -> (SearchViewModel, SpyEngine) {
        let spy = SpyEngine(SearchEngine(snapshot: TestIndex.curated, refiner: refiner))
        let model = SearchViewModel(engine: spy, coordinator: coordinator, voice: voice,
                                    settleDelay: .milliseconds(40))
        return (model, spy)
    }

    @Test func emptyFieldShowsFavoritesAndFrequent() async {
        let (model, _) = makeModel()
        model.start()
        await waitUntil { model.snapshot != nil }
        #expect(model.state == .idle)
        #expect(model.groups.map(\.section) == [.recent])
    }

    @Test func typingUpdatesEveryKeystrokeButAnnouncesOnceAfterAPause() async {
        let (model, spy) = makeModel()
        for text in ["b", "be", "bed", "bedroom", "bedroom ac"] { model.text = text }
        await waitUntil { model.announcement != nil }
        #expect(model.snapshot?.originalQuery == "bedroom ac")
        #expect(model.state == .instant)
        #expect(model.announcement?.text == model.countText)
        #expect(model.announcement?.id == 1)
        await waitUntil { spy.calls.contains("settled bedroom ac") }
        #expect(spy.calls.filter { $0.hasPrefix("settled") } == ["settled bedroom ac"])
        #expect(!spy.calls.contains { $0.hasPrefix("search submitted") })   // typing never takes the model path
    }

    @Test func submitWalksTheStatesAndAnnouncesTheRefinedList() async {
        let (model, spy) = makeModel()
        model.text = "something to cool the bedroom"
        model.submit()
        await waitUntil { model.state == .refining }
        #expect(model.state == .refining)
        await waitUntil { model.state == .refined }
        #expect(model.announcement?.text == "Results refined")
        #expect(spy.calls.contains("settled something to cool the bedroom"))
    }

    @Test func theNextPhaseWaitsWhileTheListIsTouched() async {
        let (model, _) = makeModel()
        model.text = "something to cool the bedroom"
        model.submit()
        await waitUntil { model.state == .refining }
        model.isInteracting = true
        await waitUntil { model.hasHeldUpdate }
        #expect(model.state == .refining)                   // nothing moved under the finger
        model.isInteracting = false
        #expect(model.state == .refined)
        #expect(!model.hasHeldUpdate)
    }

    @Test func editingCancelsTheRefinement() async {
        let (model, _) = makeModel()
        model.text = "something to cool the bedroom"
        model.submit()
        await waitUntil { model.state == .refining }
        model.text = "porch"
        try? await Task.sleep(for: .milliseconds(300))
        #expect(model.snapshot?.originalQuery == "porch")
        #expect(model.state == .instant)
    }

    @Test func correctionsOfferTheOriginalWords() async {
        let (model, _) = makeModel(refiner: nil)
        model.text = "bedrom ac"
        model.submit()
        await waitUntil { model.correction != nil }
        #expect(model.correction?.showing == "bedroom ac")
        #expect(model.correction?.original == "bedrom ac")
        model.searchOriginalInstead()
        await waitUntil { model.correction == nil }
        #expect(model.correction == nil)
    }

    @Test func selectingRecordsThePositionAndOpensTheDevice() async throws {
        let coordinator = CoordinatorSpy()
        let (model, spy) = makeModel(coordinator: coordinator)
        model.text = "kitchen light"
        await waitUntil { model.snapshot?.results.isEmpty == false }
        let result = try #require(model.snapshot?.results.first)
        model.select(result)
        #expect(coordinator.opened == [result.id])
        await waitUntil { spy.calls.contains("select \(result.device.name) #1") }
        #expect(spy.calls.contains("select \(result.device.name) #1"))
    }

    @Test func commandsGoThroughTheCoordinator() async {
        let coordinator = CoordinatorSpy()
        let (model, _) = makeModel(coordinator: coordinator)
        model.text = "turn off all lights"
        model.submit()
        await waitUntil { model.snapshot?.command != nil }
        model.runCommand()
        #expect(coordinator.commands.first?.verb == "turn off")
        #expect(coordinator.commands.first?.targets.count == model.snapshot?.results.count)
    }

    @Test func focusPrewarmsTheModel() async {
        let (model, spy) = makeModel()
        model.focusChanged(true)
        await waitUntil { spy.calls.contains("prewarm") }
        #expect(spy.calls.contains("prewarm"))
    }

    @Test func voiceFeedsTheSamePipelineAndSubmitsTheFinalTranscript() async {
        let voice = ScriptedVoice(transcript: [
            VoiceTranscript(text: "kitchen", isFinal: false),
            VoiceTranscript(text: "kitchen light", isFinal: true),
        ])
        let (model, spy) = makeModel(refiner: nil, voice: voice)
        #expect(model.showsVoiceButton)
        model.startVoice()
        await waitUntil { !model.isListening && model.text == "kitchen light" }
        #expect(spy.calls.contains("search typing kitchen"))
        #expect(spy.calls.contains("search submitted kitchen light"))
    }

    @Test func setQueriesCountDevices() async {
        let (model, _) = makeModel(refiner: nil)
        model.text = "all lights"
        model.submit()
        await waitUntil { model.snapshot?.setSummary != nil }
        #expect(model.countText.hasSuffix("devices"))
        #expect(model.groups.contains { $0.section == .set })
    }
}

@MainActor
@Suite("UI states")
struct SearchUIStateTests {
    func snapshot(_ phase: SearchPhase, refining: Bool = false, text: String = "lamp") -> SearchSnapshot {
        var query = ParsedQuery(raw: text, mode: .submitted)
        query.intent = text.isEmpty ? .empty : .navigational
        return SearchSnapshot(phase: phase, query: query, results: [], originalQuery: text, isRefining: refining)
    }

    @Test func mapsPhasesToStates() {
        #expect(SearchViewModel.state(for: snapshot(.instant, text: "")) == .idle)
        #expect(SearchViewModel.state(for: snapshot(.instant)) == .instant)
        #expect(SearchViewModel.state(for: snapshot(.instant, refining: true)) == .refining)
        #expect(SearchViewModel.state(for: snapshot(.hybrid)) == .hybrid)
        #expect(SearchViewModel.state(for: snapshot(.hybrid, refining: true)) == .refining)
        #expect(SearchViewModel.state(for: snapshot(.refined)) == .refined)
        #expect(SearchViewModel.state(for: snapshot(.fallback)) == .fallback)
    }
}

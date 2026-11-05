import Testing
import SearchCore
import SearchIndex
import SearchQuery
import SearchRetrieval
@testable import SearchRanking
import SearchTestSupport

@Suite("Result presenter")
struct ResultPresenterTests {
    let presenter = ResultPresenter()
    let snapshot = TestIndex.home500

    @Test func navigationalQueriesSplitIntoBestAndRelated() {
        let (query, _, result) = fused("hue go")
        #expect(query.intent == .navigational)
        let rows = presenter.fusedResults(query: query, fusion: result, snapshot: snapshot)
        #expect(rows.first?.device.name == "Hue Go")
        #expect(rows.first?.section == .best)
        #expect(rows.first?.reasons.first?.text == "Exact name")
        #expect(rows.allSatisfy { $0.section == .best || $0.section == .related })
        #expect(rows.filter { $0.section == .related }.count <= 10)
    }

    @Test func compoundQueriesPinTheExactDeviceAboveTheSet() {
        let (query, _, result) = fused("bedroom ac")
        #expect(query.intent == .compound)
        let rows = presenter.fusedResults(query: query, fusion: result, snapshot: snapshot)
        #expect(rows.map(\.device.name) == ["Bedroom AC", "Bedroom AC 2"])
        #expect(rows.map(\.section) == [.best, .set])
    }

    @Test func setQueriesUseTheSetSectionAndSummary() {
        let (query, _, result) = fused("offline cameras")
        let rows = presenter.fusedResults(query: query, fusion: result, snapshot: snapshot)
        #expect(rows.allSatisfy { $0.section == .set })
        #expect(rows.allSatisfy { $0.reasons.contains { $0.text == "Offline" } })
        let summary = ResultPresenter.setSummary(for: rows)
        #expect(summary.count == rows.count)
        #expect(summary.types.first?.label == "Camera")
    }

    @Test func reasonsExplainCorrectionsAndEntities() {
        let (query, _, result) = fused("samsng tv")
        let rows = presenter.fusedResults(query: query, fusion: result, snapshot: snapshot)
        let top = rows.first!
        #expect(top.device.name == "Samsung TV")
        #expect(top.reasons.map(\.text).contains("Typo: samsng → samsung"))
        #expect(top.reasons.map(\.text).contains("Brand: Samsung"))
    }

    @Test func highlightsUseCharacterOffsets() {
        let query = QueryParser().parse("bedroom ac", mode: .submitted, in: snapshot)
        let ranges = ResultPresenter.highlights(name: "Bedroom AC 2", query: query, pipeline: snapshot.pipeline)
        #expect(ranges == [HighlightRange(lowerBound: 0, upperBound: 7), HighlightRange(lowerBound: 8, upperBound: 10)])
        let typing = QueryParser().parse("bedr", mode: .typing, in: snapshot)
        #expect(ResultPresenter.highlights(name: "Master Bedroom TV", query: typing, pipeline: snapshot.pipeline)
                == [HighlightRange(lowerBound: 7, upperBound: 14)])
    }

    @Test func commandsCarryTheirTargets() {
        let (query, _, result) = fused("turn off hallway lights")
        let rows = presenter.fusedResults(query: query, fusion: result, snapshot: snapshot)
        let command = ResultPresenter.command(for: query, results: rows)
        #expect(command?.verb == "turn off")
        #expect(command?.targets.count == rows.count)
        #expect(!rows.isEmpty)
    }

    @Test func anActionOnANeedTargetsTheBestMatchesOnly() {
        let (query, _, result) = fused("play music in the kitchen")
        #expect(query.intent == .descriptive)
        let rows = presenter.fusedResults(query: query, fusion: result, snapshot: snapshot)
        let command = ResultPresenter.command(for: query, results: rows)
        #expect(command?.verb == "play")
        #expect(command?.targets == rows.filter { $0.section == .best }.map(\.id))
    }

    @Test func emptyStateShowsFavoritesAndFrequentDevices() {
        let rows = presenter.emptyState(snapshot: snapshot)
        #expect(rows.count == 8)
        #expect(rows.allSatisfy { $0.section == .recent })
        #expect(rows.first?.reasons.first?.text == "Favorite")
    }
}

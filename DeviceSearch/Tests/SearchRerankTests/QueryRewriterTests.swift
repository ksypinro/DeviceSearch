import Foundation
import Testing
import SearchCore
import SearchIndex
import SearchRanking
@testable import DeviceSearch
@testable import SearchRerank
import SearchTestSupport

@Suite("Query rewrite")
struct QueryRewriterTests {
    let heaterOnly = SimulatedRerankClient(typeSimilarity: { _, typeID in typeID == "heater" ? 0.9 : 0.1 })

    @Test func rewritesToKnownTypeNamesAndKeepsTheRoom() async throws {
        let query = QueryParserFixture.parse("keep the nursery toasty")
        let rewritten = try await LLMQueryRewriter(client: heaterOnly).rewrite(query, in: TestIndex.home500)
        #expect(rewritten?.hasPrefix("Heater") == true)
    }

    @Test func ignoresNumbersOutsideTheList() async throws {
        struct Wild: RewriteModelClient {
            func isAvailable() async -> Bool { true }
            func chooseTypes(_ request: RewriteModelRequest) async throws -> [Int] { [999, -1, 0] }
        }
        let query = QueryParserFixture.parse("zzqx")
        #expect(try await LLMQueryRewriter(client: Wild()).rewrite(query, in: TestIndex.home500) == nil)
    }

    @Test func promptListsOnlyTheHomesTypes() {
        let request = LLMQueryRewriter.request(for: QueryParserFixture.parse("zzqx"), in: TestIndex.tiny)
        #expect(request.types.map(\.typeID).sorted() == ["ac", "light", "lock", "tv"])
        #expect(request.prompt.contains("1 | Air Conditioner |"))
    }

    @Test func engineUsesTheRewriteAsLadderStepFour() async {
        let engine = SearchEngine(snapshot: TestIndex.home500, rewriter: LLMQueryRewriter(client: heaterOnly))
        let phases = await engine.searchAll("zzqx", mode: .submitted)
        #expect(phases.first?.noMatchesMessage != nil)
        let last = phases.last
        #expect(last?.relaxed.contains(.rewrite) == true)
        #expect(last?.correctedQuery == "Heater")
        #expect(last?.results.first?.typeLabel == "Heater")
    }
}

enum QueryParserFixture {
    static func parse(_ text: String) -> ParsedQuery {
        SearchPipeline(config: .default).parse(text, mode: .submitted, options: .standard, in: TestIndex.home500)
    }
}

import Testing
import SearchCore
import SearchIndex
@testable import SearchQuery
import SearchTestSupport

@Suite("Query lexer")
struct QueryLexerTests {
    let pipeline = TestIndex.knowledge.makePipeline()
    let lexicon = TestIndex.knowledge.lexicon

    @Test(arguments: [
        ("turn off hallway lights", "turn off", ["hallway", "lights"]),
        ("turn hallway lights off", "turn off", ["hallway", "lights"]),
        ("dim bedroom lights", "dim", ["bedroom", "lights"]),
        ("switch off the fan", "switch off", ["the", "fan"]),
    ])
    func detectsCommands(raw: String, verb: String, tokens: [String]) {
        let output = QueryLexer().lex(raw, pipeline: pipeline, lexicon: lexicon)
        #expect(output.action == verb)
        #expect(output.tokens == tokens)
    }

    @Test(arguments: ["switch bedroom", "lock front door", "lights", "turn"])
    func nounsAreNotCommands(raw: String) {
        #expect(QueryLexer().lex(raw, pipeline: pipeline, lexicon: lexicon).action == nil)
    }
}

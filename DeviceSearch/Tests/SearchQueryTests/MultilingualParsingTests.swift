import Testing
import SearchCore
import SearchIndex
@testable import SearchQuery
import SearchTestSupport

@Suite("Multilingual parsing")
struct MultilingualParsingTests {
    let parser = QueryParser()
    let home = TestIndex.home500

    @Test(arguments: [
        ("এসি", ["ac"]),
        ("বেডরুমের এসি", ["bedroom", "ac"]),       // possessive suffix "ের"
        ("লাইটগুলো", ["light"]),                    // plural suffix "গুলো" (its "ো" decomposes under NFKD)
        ("রান্নাঘরের লাইট", ["kitchen", "light"]),
        ("klimaanlage", ["ac"]),
    ])
    func recognizesLocalizedLabels(text: String, entities: [String]) {
        #expect(parser.parse(text, mode: .submitted, in: home).entities.map(\.id) == entities)
    }
}

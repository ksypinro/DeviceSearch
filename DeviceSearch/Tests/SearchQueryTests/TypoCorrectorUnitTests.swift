import Testing
import SearchCore
import SearchIndex
@testable import SearchQuery
import SearchTestSupport

@Suite("Typo corrector")
struct TypoCorrectorUnitTests {
    let corrector = TypoCorrector()
    let home = TestIndex.home500

    func classify(_ tokens: [String], _ mode: SearchMode = .submitted) -> TypoCorrector.Output {
        corrector.classify(tokens, mode: mode, options: .standard, snapshot: home)
    }

    @Test func correctsWithinTheEditBudget() {
        let output = classify(["samsng", "tv"])
        #expect(output.corrections.first?.to == "samsung")
        #expect(output.corrections.first?.confidence == 0.7)
    }

    @Test func numbersStayExact() {
        let output = classify(["tv", "2"])
        #expect(output.corrections.isEmpty)
        #expect(output.terms.last?.isNumber == true)
    }

    @Test func theLastTokenCompletesWhileTyping() {
        let output = classify(["bedr"], .typing)
        #expect(output.lastPrefix == "bedr")
        #expect(output.completions.first == "bedroom")
        #expect(output.corrections.isEmpty)
    }

    @Test func phoneticFallback() {
        #expect(classify(["fillips", "hue"]).corrections.first?.method == .phonetic)
    }
}

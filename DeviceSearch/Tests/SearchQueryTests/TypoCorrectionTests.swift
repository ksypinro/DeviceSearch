import Testing
import SearchCore
import SearchIndex
@testable import SearchQuery
import SearchTestSupport

@Suite("Typo correction")
struct TypoCorrectorTests {
    let parser = QueryParser()
    let home = TestIndex.home500

    @Test func editCorrectionWithConfidence() {
        let query = parser.parse("samsng tv", mode: .submitted, in: home)
        #expect(query.corrections == [Correction(from: "samsng", to: "samsung", method: .edit, cost: 1, confidence: 0.7)])
        #expect(query.correctedText == "samsung tv")
    }

    @Test func doubledLetterIsCheap() {
        let query = parser.parse("bedrom light", mode: .submitted, in: home)
        #expect(query.corrections.first?.to == "bedroom")
        #expect(query.corrections.first?.confidence == 0.85)
    }

    @Test func digitsAreNeverCorrected() {
        let query = parser.parse("tv 2", mode: .submitted, in: home)
        #expect(query.corrections.isEmpty)
        #expect(query.terms.last?.isNumber == true)
    }

    @Test func gluedWordsAreSplit() {
        let query = parser.parse("livingroom tv", mode: .submitted, in: home)
        #expect(query.corrections.first?.method == .split)
        #expect(query.corrections.first?.to == "living room")
        #expect(query.entities.contains { $0.kind == .room && $0.id == "living-room" })
    }

    @Test func phoneticFallbackWhenTheEditBudgetIsExceeded() {
        let query = parser.parse("fillips hue", mode: .submitted, in: home)
        #expect(query.corrections.first == Correction(from: "fillips", to: "philips", method: .phonetic, confidence: 0.6))
    }

    @Test func lastTokenIsAPrefixWhileTyping() {
        let typing = parser.parse("bedr", mode: .typing, in: home)
        #expect(typing.lastPrefix == "bedr")
        #expect(typing.completions.first == "bedroom")
        #expect(typing.corrections.isEmpty)
    }

    @Test func correctionsCanBeTurnedOff() {
        let query = parser.parse("samsng tv", mode: .submitted, options: SearchOptions(allowCorrections: false), in: home)
        #expect(query.corrections.isEmpty)
        #expect(query.terms.first?.isUnknown == true)
    }

    @Test func suffixesAreStrippedOnlyToKnownWords() {
        let query = parser.parse("বেডরুমের এসি", mode: .submitted, in: home)
        #expect(query.entities.map(\.id) == ["bedroom", "ac"])
    }

    @Test func extraBudgetFindsFartherWords() {
        // "thermstt" needs two insertions (cost 2), over the 8-letter budget of 1.5, so only the phonetic
        // fallback catches it. With 0.5 extra budget (zero-result ladder step 2) the edit correction applies.
        let strict = parser.parse("thermstt", mode: .submitted, in: home)
        let relaxed = parser.parse("thermstt", mode: .submitted, options: SearchOptions(typoBudgetBoost: 0.5), in: home)
        #expect(strict.corrections.first?.method != .edit)
        #expect(relaxed.corrections.first?.to == "thermostat")
    }
}

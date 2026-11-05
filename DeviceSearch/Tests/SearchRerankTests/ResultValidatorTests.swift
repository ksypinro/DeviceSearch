import Foundation
import Testing
import SearchCore
import SearchIndex
import SearchRanking
@testable import DeviceSearch
@testable import SearchRerank
import SearchTestSupport

@Suite("Result validator")
struct ResultValidatorTests {
    let validator = ResultValidator()
    let candidates = [
        candidate(0, score: 1.0), candidate(1, score: 0.9), candidate(2, score: 0.8, coverage: 1.0),
        candidate(3, score: 0.7, passes: false), candidate(4, score: 0.2),
    ]

    @Test func v1DropsInventedNumbersAndV2Repeats() {
        let result = validator.validate(RerankAnswer(best: [2, 19, 2, 0], related: [1, 2]), candidates: candidates,
                                        intent: .descriptive)
        #expect(result.rows.map(\.number).prefix(2) == [2, 1])
        #expect(result.interventions.contains("V1") && result.interventions.contains("V2"))
    }

    @Test func v3DropsFilterViolations() {
        let result = validator.validate(RerankAnswer(best: [4, 1], related: []), candidates: candidates, intent: .navigational)
        #expect(!result.rows.contains { $0.number == 4 })
        #expect(result.interventions.contains("V3"))
    }

    @Test func v4PinsExactMatches() {
        var withExact = candidates
        withExact[1].isExact = true
        let result = validator.validate(RerankAnswer(best: [1, 3, 2], related: []), candidates: withExact, intent: .navigational)
        #expect(result.rows.first?.number == 2)
        #expect(result.interventions.contains("V4"))
    }

    @Test func v5RecoversFullMatchesTheModelLeftOut() {
        let result = validator.validate(RerankAnswer(best: [1], related: []), candidates: candidates, intent: .navigational)
        let recovered = result.rows.first { $0.number == 3 }
        #expect(recovered?.group == .recovered)
        #expect(recovered?.modelScore == 0.30)
        #expect(result.interventions.contains("V5"))
    }

    @Test func v6BlendsAndHidesWeakRows() throws {
        let result = validator.validate(RerankAnswer(best: [2], related: [5]), candidates: candidates, intent: .descriptive)
        let top = try #require(result.rows.first)
        #expect(top.number == 2)
        let expectedTop: Double = 0.65 * 1 + 0.35 * 0.9
        #expect(abs(top.finalScore - expectedTop) < 1e-9)
        let weak = result.rows.first { $0.number == 5 }
        let expectedWeak: Double = 0.65 * 0.45 + 0.35 * 0.2
        let weakScore: Double = weak?.finalScore ?? 0
        #expect(abs(weakScore - expectedWeak) < 1e-9)
        #expect(!result.rows.contains { $0.number == 1 })          // left out by the model and not a full match
        #expect(result.interventions == ["V5"])                     // hiding alone is not an intervention
        #expect(result.notes.contains { $0.rule == "V6" })
    }

    @Test func nothingQualifyingShowsTheTopFused() {
        let weak = [candidate(0, score: 0.1), candidate(1, score: 0.05)]
        let result = validator.validate(RerankAnswer(best: [], related: []), candidates: weak, intent: .navigational)
        #expect(result.rows.map(\.number) == [1, 2])
        #expect(result.interventions == ["V6"])
    }

    @Test func lambdaDependsOnIntent() {
        #expect(validator.validate(RerankAnswer(best: [1], related: []), candidates: candidates, intent: .descriptive).lambda == 0.65)
        #expect(validator.validate(RerankAnswer(best: [1], related: []), candidates: candidates, intent: .navigational).lambda == 0.45)
    }

    @Test(arguments: [([1, 2, 3], 1.0), ([3, 2, 1], -1.0), ([2, 1, 3], 1.0 / 3)])
    func kendallTau(order: [Int], expected: Double) {
        let tau: Double = ResultValidator.kendallTau(order) ?? 99
        #expect(abs(tau - expected) < 1e-9)
    }

    @Test func lockedTopKeepsEveryCandidate() {
        let rows = validator.lockedTop([3, 42], candidates: candidates, intent: .descriptive)
        #expect(rows.first?.number == 3)
        #expect(Set(rows.map(\.number)) == [1, 2, 3, 5])           // #4 fails a filter
    }
}

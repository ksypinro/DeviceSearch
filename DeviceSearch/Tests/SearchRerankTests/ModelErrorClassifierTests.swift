import Foundation
import Testing
import SearchCore
import SearchIndex
import SearchRanking
@testable import DeviceSearch
@testable import SearchRerank
import SearchTestSupport

@Suite("Model errors")
struct ModelErrorClassifierTests {
    @Test(arguments: [
        (FakeGenerationError.exceededContextWindowSize("x") as any Error, RerankOutcome.contextWindow),
        (FakeLanguageModelError.contextSizeExceeded("x"), .contextWindow),
        (FakeGenerationError.guardrailViolation("x"), .guardrail),
        (FakeGenerationError.unsupportedLanguageOrLocale("x"), .unsupportedLanguage),
        (FakeGenerationError.assetsUnavailable("x"), .unavailable),
        (FakeGenerationError.rateLimited("x"), .failed),
        (CancellationError(), .cancelled),
        (DeadlineExceeded(), .timeout),
    ])
    func classifies(error: any Error, expected: RerankOutcome) {
        #expect(ModelErrorClassifier.classify(error) == expected)
    }
}

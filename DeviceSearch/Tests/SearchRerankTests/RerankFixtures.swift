import Foundation
import Synchronization
import SearchCore
import SearchIndex
import SearchRanking
@testable import DeviceSearch
@testable import SearchRerank
import SearchTestSupport

/// A refinement request for `text`, built the way the engine builds one (top K fused candidates).
func refinementRequest(_ text: String, snapshot: IndexSnapshot = TestIndex.home500,
                       context: PresentationContext = PresentationContext(),
                       config: SearchConfig = .default) -> RefinementRequest {
    let pipeline = SearchPipeline(config: config)
    let parsed = pipeline.parse(text, mode: .submitted, options: .standard, in: snapshot)
    let (query, fusion) = pipeline.fuse(pipeline.lexicalLists(parsed, in: snapshot), query: parsed, in: snapshot)
    return RefinementRequest(query: query, candidates: fusion.top(config.candidateCount), snapshot: snapshot,
                             context: context, config: config)
}

/// A candidate with chosen scores, for validator unit tests.
func candidate(_ document: Int, score: Double, coverage: Double = 0.5, exact: Bool = false,
               passes: Bool = true) -> FusedCandidate {
    var candidate = FusedCandidate(document: document)
    candidate.score = score
    candidate.coverage = coverage
    candidate.isExact = exact
    candidate.passesHardFilters = passes
    return candidate
}

/// Returns a fixed answer and counts calls. Optional context size for budget tests.
final class ScriptedClient: RerankModelClient {
    let answer: RerankAnswer
    let available: Bool
    let window: Int
    let error: (any Error)?
    private let calls = Mutex(0)

    init(_ answer: RerankAnswer = RerankAnswer(best: [], related: []), available: Bool = true, window: Int = 4096,
         error: (any Error)? = nil) {
        self.answer = answer
        self.available = available
        self.window = window
        self.error = error
    }

    var callCount: Int { calls.withLock { $0 } }

    func isAvailable() async -> Bool { available }
    func prewarm() async {}
    func contextSize() async -> Int { window }

    func rank(_ request: RerankModelRequest) async throws -> RerankAnswer {
        calls.withLock { $0 += 1 }
        if let error { throw error }
        return answer
    }
}

/// Error shapes of both SDK generations, for the classifier.
enum FakeGenerationError: Error {
    case exceededContextWindowSize(String)
    case guardrailViolation(String)
    case unsupportedLanguageOrLocale(String)
    case assetsUnavailable(String)
    case rateLimited(String)
}

enum FakeLanguageModelError: Error {
    case contextSizeExceeded(String)
}

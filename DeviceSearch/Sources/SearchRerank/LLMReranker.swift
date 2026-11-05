import SearchCore
import SearchIndex
import SearchRanking
import DeviceSearch

/// The milestone-3 plug-in (design doc §8–§9): prompt → model → validator → rows.
///
/// Wiring: `DeviceSearchComponents(…, refiner: LLMReranker(client: FoundationModelsClient()))`.
/// The engine calls it only for submitted searches the gate sends to the model, under a 2 s deadline.
public final class LLMReranker: ResultRefining {
    public let client: any RerankModelClient

    public init(client: any RerankModelClient) {
        self.client = client
    }

    public func isAvailable() async -> Bool { await client.isAvailable() }

    public func prewarm() async { await client.prewarm() }

    public func refine(_ request: RefinementRequest) async throws -> RefinementOutcome {
        try await run(request, partial: nil)
    }

    public func refine(_ request: RefinementRequest,
                       partial: @escaping @Sendable ([SearchResult]) async -> Void) async throws -> RefinementOutcome {
        try await run(request, partial: partial)
    }

    /// The model request for a refinement (exposed for tests and the evaluation harness).
    public static func modelRequest(for request: RefinementRequest) -> RerankModelRequest {
        let rendered = RerankPrompt.render(request)
        return RerankModelRequest(instructions: RerankPrompt.instructions, prompt: rendered.text, data: rendered.data,
                                  maxBest: request.config.maxBest, maxRelated: request.config.maxRelated,
                                  maxResponseTokens: request.config.maxResponseTokens)
    }

    private func run(_ request: RefinementRequest,
                     partial: (@Sendable ([SearchResult]) async -> Void)?) async throws -> RefinementOutcome {
        guard !request.candidates.isEmpty else { throw RefinementFailure(.failed) }
        let modelRequest = Self.modelRequest(for: request)
        guard await ContextBudget.measure(modelRequest, client: client).fits else {
            throw RefinementFailure(.contextWindow)
        }
        let validator = ResultValidator(config: request.config)
        let answer: RerankAnswer
        do {
            if let partial {
                answer = try await client.rankStreaming(modelRequest) { best in
                    let rows = validator.lockedTop(best, candidates: request.candidates, intent: request.query.intent)
                    await partial(Self.results(rows, request: request))
                }
            } else {
                answer = try await client.rank(modelRequest)
            }
        } catch {
            throw RefinementFailure(ModelErrorClassifier.classify(error))
        }
        try Task.checkCancellation()
        let validation = validator.validate(answer, candidates: request.candidates, intent: request.query.intent)
        return RefinementOutcome(results: Self.results(validation.rows, request: request),
                                 interventions: validation.interventions, kendallTau: validation.kendallTau)
    }

    /// Rows become results with deterministic reasons (never model text) and their movement against fused order.
    static func results(_ rows: [ResultValidator.Row], request: RefinementRequest) -> [SearchResult] {
        let presenter = ResultPresenter(config: request.config)
        return rows.enumerated().map { index, row in
            presenter.makeResult(row.candidate, section: row.group.section, score: row.finalScore, query: request.query,
                                 snapshot: request.snapshot, context: request.context,
                                 rankChange: (row.number - 1) - index)
        }
    }
}

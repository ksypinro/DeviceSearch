import SearchCore
import DeviceSearch

/// The model's answer: local candidate numbers only (L04). Never names, never reasons.
public struct RerankAnswer: Sendable, Equatable, Codable {
    /// Candidates that clearly fit, best first (at most 8).
    public var best: [Int]
    /// Candidates that loosely fit (at most 6).
    public var related: [Int]

    public init(best: [Int], related: [Int]) {
        self.best = best
        self.related = related
    }
}

/// One re-rank call.
public struct RerankModelRequest: Sendable, Equatable {
    public var instructions: String
    public var prompt: String
    public var data: RerankPromptData
    public var maxBest: Int
    public var maxRelated: Int
    public var maxResponseTokens: Int

    public init(instructions: String, prompt: String, data: RerankPromptData, maxBest: Int, maxRelated: Int,
                maxResponseTokens: Int) {
        self.instructions = instructions
        self.prompt = prompt
        self.data = data
        self.maxBest = maxBest
        self.maxRelated = maxRelated
        self.maxResponseTokens = maxResponseTokens
    }
}

/// A language model that can rank candidates (design doc §8). `FoundationModelsClient` is the production
/// implementation; `SimulatedRerankClient` is the deterministic stand-in for tests, previews and evaluation.
///
/// Implementations throw `RefinementFailure` with a classified outcome (timeout, guardrail, context window…).
public protocol RerankModelClient: Sendable {
    /// Model ready and conditions allow it (no Low Power Mode, thermal state below serious).
    func isAvailable() async -> Bool
    /// Loads the model and a session ahead of the first request.
    func prewarm() async
    func rank(_ request: RerankModelRequest) async throws -> RerankAnswer
    /// Streaming variant (L08): calls `onBest` once the `best` array is complete, before `related` finishes.
    func rankStreaming(_ request: RerankModelRequest,
                       onBest: @escaping @Sendable ([Int]) async -> Void) async throws -> RerankAnswer
    /// Tokens the model's context window holds (4,096 for the iOS 26 system model).
    func contextSize() async -> Int
    /// Exact token count of a text, or nil when the API is unavailable (before iOS 26.4).
    func tokenCount(_ text: String) async -> Int?
}

extension RerankModelClient {
    public func rankStreaming(_ request: RerankModelRequest,
                              onBest: @escaping @Sendable ([Int]) async -> Void) async throws -> RerankAnswer {
        let answer = try await rank(request)
        await onBest(answer.best)
        return answer
    }

    public func contextSize() async -> Int { 4096 }

    public func tokenCount(_ text: String) async -> Int? { nil }
}

/// One rewrite call: pick device types (by number) that would satisfy a query that matched nothing.
public struct RewriteModelRequest: Sendable, Equatable {
    public struct TypeRow: Sendable, Equatable {
        public var number: Int
        public var typeID: String
        public var label: String
        public var description: String
    }

    public var instructions: String
    public var prompt: String
    public var query: String
    public var types: [TypeRow]
    public var maxTypes: Int
    public var maxResponseTokens: Int
}

/// A model that can choose device types for a query (zero-result ladder step 4).
public protocol RewriteModelClient: Sendable {
    func isAvailable() async -> Bool
    /// Numbers of the chosen types, best first.
    func chooseTypes(_ request: RewriteModelRequest) async throws -> [Int]
}

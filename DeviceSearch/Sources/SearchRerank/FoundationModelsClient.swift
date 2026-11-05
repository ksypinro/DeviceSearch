#if canImport(FoundationModels)
import Foundation
import FoundationModels
import SearchCore
import DeviceSearch

/// Guided-generation output of a re-rank: two short integer arrays and nothing else (L04).
@Generable
struct RerankOutput {
    @Guide(description: "Numbers of candidates that clearly fit the query, best first", .maximumCount(8))
    var best: [Int]

    @Guide(description: "Numbers of candidates that loosely fit the query", .maximumCount(6))
    var related: [Int]
}

/// Guided-generation output of a rewrite: up to three type numbers.
@Generable
struct RewriteOutput {
    @Guide(description: "Numbers of device types that would satisfy the query, best first", .maximumCount(3))
    var types: [Int]
}

/// Apple's on-device model behind the re-rank and rewrite contracts (design doc §8).
///
/// - One fresh session per query: no transcript growth, nothing leaks between queries. A spare session is
///   prewarmed when the search field gains focus and again after each re-rank (the engine calls `prewarm`).
/// - Greedy sampling and a 64-token response cap. The engine adds the 2 s deadline.
/// - Unavailable when Apple Intelligence is off, the device is not eligible or the model is still
///   downloading, in Low Power Mode, or at serious thermal state. Every case falls back to the fused order.
public actor FoundationModelsClient: RerankModelClient, RewriteModelClient {
    private let model: SystemLanguageModel
    private let conditions: any DeviceConditions
    private var spare: LanguageModelSession?

    public init(model: SystemLanguageModel = .default, conditions: any DeviceConditions = SystemDeviceConditions()) {
        self.model = model
        self.conditions = conditions
    }

    public func isAvailable() async -> Bool {
        guard case .available = model.availability else { return false }
        return !conditions.isLowPowerModeEnabled && !conditions.isThermalStateSeriousOrWorse
    }

    public func prewarm() async {
        guard spare == nil, case .available = model.availability else { return }
        let session = LanguageModelSession(model: model, instructions: RerankPrompt.instructions)
        session.prewarm()
        spare = session
    }

    /// The model's context window (L07). `contextSize` is back-deployed to iOS 26.0.
    public func contextSize() async -> Int {
        (try? model.contextSize) ?? 4096
    }

    /// Exact token counts from iOS 26.4 (L10); the caller falls back to the character estimate before that.
    public func tokenCount(_ text: String) async -> Int? {
        if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) {
            return try? await model.tokenCount(for: Instructions { text })
        }
        return nil
    }

    public func rank(_ request: RerankModelRequest) async throws -> RerankAnswer {
        let session = takeSession(instructions: request.instructions)
        do {
            let response = try await session.respond(to: request.prompt, generating: RerankOutput.self,
                                                     options: Self.options(maxTokens: request.maxResponseTokens))
            return RerankAnswer(best: response.content.best, related: response.content.related)
        } catch {
            throw RefinementFailure(ModelErrorClassifier.classify(error))
        }
    }

    public func chooseTypes(_ request: RewriteModelRequest) async throws -> [Int] {
        let session = LanguageModelSession(model: model, instructions: request.instructions)
        do {
            let response = try await session.respond(to: request.prompt, generating: RewriteOutput.self,
                                                     options: Self.options(maxTokens: request.maxResponseTokens))
            return response.content.types
        } catch {
            throw RefinementFailure(ModelErrorClassifier.classify(error))
        }
    }

    /// The prewarmed session when it was made for these instructions, otherwise a new one. Each is used once.
    func takeSession(instructions: String) -> LanguageModelSession {
        defer { spare = nil }
        if let spare, instructions == RerankPrompt.instructions { return spare }
        return LanguageModelSession(model: model, instructions: instructions)
    }

    static func options(maxTokens: Int) -> GenerationOptions {
        GenerationOptions(sampling: .greedy, maximumResponseTokens: maxTokens)
    }
}
#endif

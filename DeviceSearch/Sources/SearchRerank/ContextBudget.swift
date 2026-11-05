import SearchCore
import DeviceSearch

/// Context accounting (design doc §8, L07/L10): instructions, schema, prompt and response share one window.
public struct ContextBudget: Sendable, Equatable {
    public var instructions: Int
    public var schema: Int
    public var prompt: Int
    public var response: Int
    public var contextSize: Int
    /// True when the counts came from the model's tokenizer (iOS 26.4+) rather than the character estimate.
    public var isExact: Bool

    public var total: Int { instructions + schema + prompt + response }
    public var fits: Bool { total <= contextSize }

    /// Measures a request with the client's tokenizer when it has one, otherwise with the estimate.
    public static func measure(_ request: RerankModelRequest, client: any RerankModelClient) async -> ContextBudget {
        let exactInstructions = await client.tokenCount(request.instructions)
        let exactPrompt = await client.tokenCount(request.prompt)
        let isExact = exactInstructions != nil && exactPrompt != nil
        return ContextBudget(
            instructions: exactInstructions ?? RerankPrompt.estimatedTokens(request.instructions),
            schema: RerankPrompt.schemaTokenEstimate,
            prompt: exactPrompt ?? RerankPrompt.estimatedTokens(request.prompt),
            response: request.maxResponseTokens,
            contextSize: await client.contextSize(),
            isExact: isExact)
    }
}

#if canImport(FoundationModels)
import FoundationModels
import SearchCore
import DeviceSearch

/// Streaming add-on (design doc §8 L08, decision D18), used only when `streamingRerankEnabled` is on.
///
/// Properties are generated in declaration order, so once the partial `related` array appears, `best` is
/// complete and the top rows can lock in. If this file does not compile with your SDK (the String-prompt
/// overload of `streamResponse` changed between the iOS 26 and 27 SDKs), delete it: the protocol's default
/// `rankStreaming` then calls the non-streaming `rank`.
extension FoundationModelsClient {
    public func rankStreaming(_ request: RerankModelRequest,
                              onBest: @escaping @Sendable ([Int]) async -> Void) async throws -> RerankAnswer {
        let session = takeSession(instructions: request.instructions)
        var best: [Int] = []
        var related: [Int] = []
        var locked = false
        do {
            let stream = session.streamResponse(to: request.prompt, generating: RerankOutput.self,
                                                options: Self.options(maxTokens: request.maxResponseTokens))
            for try await snapshot in stream {
                best = snapshot.content.best ?? best
                related = snapshot.content.related ?? related
                if !locked, snapshot.content.related != nil, !best.isEmpty {
                    locked = true
                    await onBest(best)
                }
            }
        } catch {
            throw RefinementFailure(ModelErrorClassifier.classify(error))
        }
        if !locked { await onBest(best) }
        return RerankAnswer(best: best, related: related)
    }
}
#endif

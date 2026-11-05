import Foundation
import SearchCore
import SearchIndex
import SearchKnowledge
import DeviceSearch

/// Keeps the vector store warm (design doc §11, X04/X06):
/// - after every snapshot swap, embeds only devices whose content hash is not cached, at utility priority;
/// - publishes a new vector store every `batchSize` devices so semantic search improves while warming;
/// - embeds each device-type card once per model, for concept routing;
/// - saves the cache to disk when it changed.
public actor EmbeddingPipeline {
    private let embedder: any TextEmbedding
    private let cache: EmbeddingCache
    private let knowledge: KnowledgeBase
    private let cacheURL: URL?
    private let telemetry: any SearchTelemetry
    private let batchSize: Int
    private var warming: Task<Void, Never>?

    public init(embedder: any TextEmbedding, cache: EmbeddingCache, knowledge: KnowledgeBase, cacheURL: URL? = nil,
                telemetry: any SearchTelemetry = NoopTelemetry(), batchSize: Int = 32) {
        self.embedder = embedder
        self.cache = cache
        self.knowledge = knowledge
        self.cacheURL = cacheURL
        self.telemetry = telemetry
        self.batchSize = max(1, batchSize)
    }

    /// Starts warming for `snapshot`, cancelling any warming for an older snapshot.
    public func warm(_ snapshot: IndexSnapshot, sink: any VectorUpdateSink) {
        warming?.cancel()
        warming = Task(priority: .utility) { [weak self] in
            await self?.run(snapshot, sink: sink)
        }
    }

    /// Waits for the current warming pass (tests, evaluation).
    public func waitUntilWarm() async {
        await warming?.value
    }

    private func run(_ snapshot: IndexSnapshot, sink: any VectorUpdateSink) async {
        let clock = ContinuousClock()
        let start = clock.now
        do { try await embedder.prepare() } catch { return }

        for card in knowledge.types where card.id != KnowledgeBase.otherTypeID {
            guard cache.cachedConceptVectors()[card.id] == nil else { continue }
            if Task.isCancelled { return }
            if let vector = try? await embedder.embed(Self.conceptText(card)) { cache.storeConcept(vector, forType: card.id) }
        }

        let missing = snapshot.documents.filter {
            cache.cachedVector(forContentHash: $0.contentHash) == nil && embedder.supports($0.embeddingText)
        }
        var embedded = 0
        for document in missing {
            if Task.isCancelled { return }
            if let vector = try? await embedder.embed(document.embeddingText) {
                cache.store(vector, forContentHash: document.contentHash)
                embedded += 1
            }
            if embedded > 0, embedded % batchSize == 0 { await publish(snapshot, sink: sink) }
        }
        if Task.isCancelled { return }
        cache.retain(contentHashes: Set(snapshot.documents.map(\.contentHash)))
        await publish(snapshot, sink: sink)
        if embedded > 0 { telemetry.record(.embeddingsUpdated(count: embedded, duration: clock.now - start)) }
        if let cacheURL, cache.isDirty { try? cache.save(to: cacheURL) }
    }

    private func publish(_ snapshot: IndexSnapshot, sink: any VectorUpdateSink) async {
        var raw: [Int: [Float]] = [:]
        for document in snapshot.documents {
            if let vector = cache.cachedVector(forContentHash: document.contentHash) { raw[document.ordinal] = vector }
        }
        let store = VectorStore.build(capacity: snapshot.count, dimension: cache.dimension,
                                      modelVersion: cache.modelVersion, raw: raw, center: cache.centersVectors)
        let concepts = ConceptVectors.prepare(cache.cachedConceptVectors(), with: store)
        await sink.applyVectors(store, concepts: concepts, generation: snapshot.generation)
    }

    /// "Air Conditioner. Cools a room and controls its temperature; part of climate control. (ac, aircon, air con)"
    public static func conceptText(_ card: DeviceTypeCard) -> String {
        let synonyms = card.synonyms.prefix(4).joined(separator: ", ")
        return "\(card.label). \(card.description)" + (synonyms.isEmpty ? "" : " (\(synonyms))")
    }
}

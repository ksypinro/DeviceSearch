import Foundation
import Synchronization
import SearchCore
import SearchKnowledge
import SearchText

/// Builds a complete `IndexSnapshot` from the home's devices (design doc §11: full lexical rebuild).
/// At 500 devices this takes a few milliseconds and can never drift, unlike incremental updates.
public struct IndexBuilder: Sendable {
    public let knowledge: KnowledgeBase
    public let pipeline: TextPipeline
    public let encoder: any PhoneticEncoding
    /// Everything derived from the knowledge base once per builder (phrases, resolver, per-type tokens).
    /// A single immutable reference keeps the builder cheap to copy.
    private let prepared: Prepared

    final class Prepared: Sendable {
        let basePhrases: PhraseDictionary
        let meaningWords: Set<String>
        let resolver: EntityResolver
        let documentBuilder: DocumentBuilder
        /// Phonetic keys of every knowledge-base term (they are in every home's vocabulary).
        let phoneticKeys: [String: String]
        /// Manufacturer and room strings resolve the same way on every rebuild.
        let brands = Mutex<[String: ResolvedBrand]>([:])
        let rooms = Mutex<[String: ResolvedRoom?]>([:])

        init(knowledge: KnowledgeBase, pipeline: TextPipeline, encoder: any PhoneticEncoding, maxPhraseLength: Int) {
            basePhrases = PhraseDictionary(knowledge: knowledge, pipeline: pipeline, maxPhraseLength: maxPhraseLength)
            meaningWords = Set(knowledge.lexicon.meaningWords.keys.map { pipeline.stemmer.stem($0) })
            resolver = EntityResolver(knowledge: knowledge, pipeline: pipeline)
            documentBuilder = DocumentBuilder(knowledge: knowledge, pipeline: pipeline)
            var keys: [String: String] = [:]
            for term in basePhrases.entityTokens.union(meaningWords) { keys[term] = encoder.key(for: term) }
            phoneticKeys = keys
        }

        func brand(for manufacturer: String) -> ResolvedBrand {
            if let cached = brands.withLock({ $0[manufacturer] }) { return cached }
            let resolved = resolver.brand(for: manufacturer)
            brands.withLock { $0[manufacturer] = resolved }
            return resolved
        }

        func room(for name: String?) -> ResolvedRoom? {
            let key = name ?? ""
            if let cached = rooms.withLock({ $0[key] }) { return cached }
            let resolved = resolver.room(for: name)
            rooms.withLock { $0[key] = resolved }
            return resolved
        }
    }

    public init(knowledge: KnowledgeBase, pipeline: TextPipeline? = nil,
                encoder: any PhoneticEncoding = MetaphoneLite(), maxPhraseLength: Int = 4) {
        let pipeline = pipeline ?? knowledge.makePipeline()
        self.knowledge = knowledge
        self.pipeline = pipeline
        self.encoder = encoder
        self.prepared = Prepared(knowledge: knowledge, pipeline: pipeline, encoder: encoder, maxPhraseLength: maxPhraseLength)
    }

    /// Builds the snapshot. Devices keep their array order as ordinals; pass them in a stable order.
    public func build(homeID: HomeID, devices: [DeviceRecord], generation: UInt64 = 0,
                      priors: (any PriorProviding)? = nil, aliases: (any AliasProviding)? = nil,
                      vectorSource: (any VectorSource)? = nil) -> IndexSnapshot {
        let clock = ContinuousClock()
        let start = clock.now
        let priorValues = (priors ?? UsagePriorProvider()).priors(for: devices)
        let documentBuilder = prepared.documentBuilder
        let meaningWords = prepared.meaningWords

        var brandCache: [String: ResolvedBrand] = [:]
        var brandTokens: [String: [String]] = [:]
        var roomCache: [String: ResolvedRoom?] = [:]
        var phrases = prepared.basePhrases
        var aliasesByOrdinal: [Int: [String]] = [:]
        var documents: [SearchDocument] = []
        documents.reserveCapacity(devices.count)

        for (ordinal, device) in devices.enumerated() {
            let brand: ResolvedBrand
            if let cached = brandCache[device.manufacturer] {
                brand = cached
            } else {
                brand = prepared.brand(for: device.manufacturer)
                brandCache[device.manufacturer] = brand
                if !brand.isKnown { phrases.addBrand(id: brand.id, label: brand.name, names: [brand.name]) }
            }
            let roomKey = device.room ?? ""
            let room: ResolvedRoom?
            if let cached = roomCache[roomKey] {
                room = cached
            } else {
                room = prepared.room(for: device.room)
                roomCache[roomKey] = room
                if let room, !room.isKnown { phrases.addRoom(id: room.id, label: room.name, names: [room.name]) }
            }
            let deviceAliases = aliases?.aliases(for: device.id) ?? []
            if !deviceAliases.isEmpty { aliasesByOrdinal[ordinal] = deviceAliases }
            let tokens = brandTokens[brand.id] ?? documentBuilder.brandTokens(for: brand)
            brandTokens[brand.id] = tokens
            documents.append(documentBuilder.makeDocument(
                ordinal: ordinal, device: device, brand: brand, room: room, aliases: deviceAliases,
                prior: priorValues[device.id] ?? 0, brandTokens: tokens))
        }

        var vectors = VectorStore.empty(capacity: documents.count)
        var concepts = ConceptVectors.empty
        if let source = vectorSource, source.dimension > 0 {
            var raw: [Int: [Float]] = [:]
            for document in documents {
                if let vector = source.cachedVector(forContentHash: document.contentHash) { raw[document.ordinal] = vector }
            }
            vectors = VectorStore.build(capacity: documents.count, dimension: source.dimension,
                                        modelVersion: source.modelVersion, raw: raw, center: source.centersVectors)
            concepts = ConceptVectors.prepare(source.cachedConceptVectors(), with: vectors)
        }

        let vocabulary = Vocabulary(documents: documents, entityTokens: phrases.entityTokens,
                                    meaningWords: meaningWords, encoder: encoder, phoneticCache: prepared.phoneticKeys)
        return IndexSnapshot(
            homeID: homeID, generation: generation, documents: documents, knowledge: knowledge, pipeline: pipeline,
            encoder: encoder, phrases: phrases, vocabulary: vocabulary,
            inverted: InvertedIndex(documents: documents),
            names: NameIndex(documents: documents, pipeline: pipeline, aliases: aliasesByOrdinal),
            fuzzy: FuzzyIndex(documents: documents, encoder: encoder, phoneticCache: prepared.phoneticKeys),
            facets: FacetIndex(documents: documents), vectors: vectors, concepts: concepts,
            meaningWords: meaningWords, builtAt: Date(), buildDuration: clock.now - start)
    }
}

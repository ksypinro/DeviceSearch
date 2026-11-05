import Foundation
import SearchCore
import SearchKnowledge
import SearchText

/// Supplies usage priors at index time. The default uses `DeviceRecord.usage`;
/// personalization (milestone 4) supplies decayed counts instead.
public protocol PriorProviding: Sendable {
    /// Prior 0...1 per device.
    func priors(for devices: [DeviceRecord]) -> [DeviceID: Double]
}

/// Supplies learned nicknames at index time (milestone 4).
public protocol AliasProviding: Sendable {
    func aliases(for device: DeviceID) -> [String]
}

/// Supplies cached raw embeddings at index time so a rebuild does not have to wait for re-embedding (milestone 2).
public protocol VectorSource: Sendable {
    var dimension: Int { get }
    var modelVersion: String { get }
    /// Whether vectors should be mean-centered (true for contextual embeddings).
    var centersVectors: Bool { get }
    func cachedVector(forContentHash hash: String) -> [Float]?
    /// Raw embeddings of the type cards, keyed by type id (empty until computed).
    func cachedConceptVectors() -> [String: [Float]]
}

/// prior = 0.7 × log(1 + uses) / log(1 + max uses) + 0.3 × favorite (design doc §15).
public struct UsagePriorProvider: PriorProviding {
    public init() {}

    public func priors(for devices: [DeviceRecord]) -> [DeviceID: Double] {
        let maxUses = max(1, devices.map { $0.usage?.useCount ?? 0 }.max() ?? 1)
        var result: [DeviceID: Double] = [:]
        for device in devices {
            let uses = Double(max(0, device.usage?.useCount ?? 0))
            let favorite = device.usage?.isFavorite == true ? 1.0 : 0.0
            result[device.id] = 0.7 * log(1 + uses) / log(1 + Double(maxUses)) + 0.3 * favorite
        }
        return result
    }
}

/// Everything a query reads, as one immutable value (design doc §4). The data plane builds a new snapshot
/// and swaps it in; queries in flight keep the snapshot they started with.
public struct IndexSnapshot: Sendable {
    public let homeID: HomeID
    /// Increases with every rebuild.
    public let generation: UInt64
    public internal(set) var documents: [SearchDocument]
    public let knowledge: KnowledgeBase
    public let pipeline: TextPipeline
    public let encoder: any PhoneticEncoding
    /// Knowledge-base phrases plus the home's own rooms and brands.
    public let phrases: PhraseDictionary
    public let vocabulary: Vocabulary
    public let inverted: InvertedIndex
    public let names: NameIndex
    public let fuzzy: FuzzyIndex
    public internal(set) var facets: FacetIndex
    public internal(set) var vectors: VectorStore
    public internal(set) var concepts: ConceptVectors
    /// Meaning-lexicon words, stemmed.
    public let meaningWords: Set<String>
    public let builtAt: Date
    public let buildDuration: Duration
    let ordinalByID: [DeviceID: Int]

    public init(homeID: HomeID, generation: UInt64, documents: [SearchDocument], knowledge: KnowledgeBase,
                pipeline: TextPipeline, encoder: any PhoneticEncoding, phrases: PhraseDictionary,
                vocabulary: Vocabulary, inverted: InvertedIndex, names: NameIndex, fuzzy: FuzzyIndex,
                facets: FacetIndex, vectors: VectorStore, concepts: ConceptVectors, meaningWords: Set<String>,
                builtAt: Date, buildDuration: Duration) {
        self.homeID = homeID
        self.generation = generation
        self.documents = documents
        self.knowledge = knowledge
        self.pipeline = pipeline
        self.encoder = encoder
        self.phrases = phrases
        self.vocabulary = vocabulary
        self.inverted = inverted
        self.names = names
        self.fuzzy = fuzzy
        self.facets = facets
        self.vectors = vectors
        self.concepts = concepts
        self.meaningWords = meaningWords
        self.builtAt = builtAt
        self.buildDuration = buildDuration
        var byID: [DeviceID: Int] = [:]
        for document in documents { byID[document.id] = document.ordinal }
        self.ordinalByID = byID
    }

    public var count: Int { documents.count }
    public var isEmpty: Bool { documents.isEmpty }

    public func ordinal(of id: DeviceID) -> Int? { ordinalByID[id] }

    public func document(for id: DeviceID) -> SearchDocument? { ordinalByID[id].map { documents[$0] } }

    /// A copy with one device's live status updated in the documents and the facet bitsets (design doc §11).
    /// Returns nil when the device is not in this snapshot.
    public func updatingStatus(_ status: DeviceStatus?, for id: DeviceID) -> IndexSnapshot? {
        guard let ordinal = ordinalByID[id] else { return nil }
        var copy = self
        copy.documents[ordinal].device.status = status
        copy.facets.setStatus(status, at: ordinal)
        return copy
    }

    /// A copy with new priors (usage changed without a rebuild).
    public func updatingPriors(_ priors: [DeviceID: Double]) -> IndexSnapshot {
        var copy = self
        for (id, prior) in priors {
            if let ordinal = ordinalByID[id] { copy.documents[ordinal].prior = min(1, max(0, prior)) }
        }
        return copy
    }

    /// A copy with new device and concept vectors (semantic warming).
    public func withVectors(_ vectors: VectorStore, concepts: ConceptVectors? = nil) -> IndexSnapshot {
        precondition(vectors.capacity == count, "vector store capacity must equal document count")
        var copy = self
        copy.vectors = vectors
        if let concepts { copy.concepts = concepts }
        return copy
    }
}

import SearchCore

/// Device embeddings for the semantic retriever (design doc §6), stored mean-centered and unit length
/// (decision D06): subtracting the home's mean vector removes the shared direction that makes every
/// pair of sentences look similar, so absolute thresholds like 0.35 become meaningful.
public struct VectorStore: Sendable {
    public let dimension: Int
    public let modelVersion: String
    /// capacity × dimension, row-major, centered and normalized. Zero rows for missing vectors.
    public let vectors: [Float]
    /// Ordinals that have a vector. Others are still warming and are skipped.
    public let present: Bitset
    /// The mean that was subtracted; queries are centered with it too.
    public let mean: [Float]

    public init(dimension: Int, modelVersion: String, vectors: [Float], present: Bitset, mean: [Float]) {
        precondition(vectors.count == present.capacity * dimension, "vectors must be capacity × dimension")
        self.dimension = dimension
        self.modelVersion = modelVersion
        self.vectors = vectors
        self.present = present
        self.mean = mean
    }

    /// A store with no vectors (lexical-only search or still warming).
    public static func empty(capacity: Int) -> VectorStore {
        VectorStore(dimension: 0, modelVersion: "", vectors: [], present: Bitset(capacity: capacity), mean: [])
    }

    public var capacity: Int { present.capacity }
    public var isEmpty: Bool { present.isEmpty }
    public var warmedCount: Int { present.count }

    public func vector(at ordinal: Int) -> ArraySlice<Float>? {
        guard dimension > 0, present.contains(ordinal) else { return nil }
        return vectors[(ordinal * dimension)..<((ordinal + 1) * dimension)]
    }

    /// Builds a store from raw (uncentered) vectors keyed by ordinal.
    /// - Parameter center: subtract the mean of the present vectors first (recommended for contextual embeddings).
    public static func build(capacity: Int, dimension: Int, modelVersion: String,
                             raw: [Int: [Float]], center: Bool) -> VectorStore {
        guard dimension > 0 else { return .empty(capacity: capacity) }
        var mean = [Float](repeating: 0, count: dimension)
        let usable = raw.filter { $0.key >= 0 && $0.key < capacity && $0.value.count == dimension }
        if center, !usable.isEmpty {
            for vector in usable.values { for i in 0..<dimension { mean[i] += vector[i] } }
            let count = Float(usable.count)
            for i in 0..<dimension { mean[i] /= count }
        }
        var matrix = [Float](repeating: 0, count: capacity * dimension)
        var present = Bitset(capacity: capacity)
        for (ordinal, vector) in usable {
            var row = vector
            if center { for i in 0..<dimension { row[i] -= mean[i] } }
            guard let unit = normalized(row) else { continue }
            matrix.replaceSubrange((ordinal * dimension)..<((ordinal + 1) * dimension), with: unit)
            present.insert(ordinal)
        }
        return VectorStore(dimension: dimension, modelVersion: modelVersion, vectors: matrix, present: present,
                           mean: center ? mean : [])
    }

    /// Centers (with this store's mean) and normalizes a query vector. Nil for a zero or mismatched vector.
    public func prepareQuery(_ vector: [Float]) -> [Float]? {
        guard vector.count == dimension else { return nil }
        var row = vector
        if mean.count == dimension { for i in 0..<dimension { row[i] -= mean[i] } }
        return Self.normalized(row)
    }

    public static func normalized(_ vector: [Float]) -> [Float]? {
        var sum: Float = 0
        for value in vector { sum += value * value }
        guard sum > 1e-12 else { return nil }
        let length = sum.squareRoot()
        return vector.map { $0 / length }
    }
}

/// Embeddings of the knowledge base's type cards for concept routing (design doc §6).
public struct ConceptVectors: Sendable {
    public let modelVersion: String
    public let typeIDs: [String]
    /// One prepared (centered, unit) vector per type id.
    public let vectors: [[Float]]

    public init(modelVersion: String, typeIDs: [String], vectors: [[Float]]) {
        precondition(typeIDs.count == vectors.count, "one vector per type id")
        self.modelVersion = modelVersion
        self.typeIDs = typeIDs
        self.vectors = vectors
    }

    public static let empty = ConceptVectors(modelVersion: "", typeIDs: [], vectors: [])
    public var isEmpty: Bool { typeIDs.isEmpty }

    /// Centers raw type-card vectors with the device store's mean, in type-id order.
    public static func prepare(_ raw: [String: [Float]], with store: VectorStore) -> ConceptVectors {
        var ids: [String] = []
        var prepared: [[Float]] = []
        for id in raw.keys.sorted() {
            if let vector = raw[id].flatMap(store.prepareQuery) {
                ids.append(id)
                prepared.append(vector)
            }
        }
        return ConceptVectors(modelVersion: store.modelVersion, typeIDs: ids, vectors: prepared)
    }
}

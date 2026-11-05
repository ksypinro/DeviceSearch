import Foundation
import Synchronization
import SearchCore
import SearchIndex

/// Raw embeddings keyed by device content hash, for one embedding model (design doc §11: cached by content hash
/// and model version). Thread-safe and synchronous, so the index builder can read it during a rebuild.
///
/// On disk: a small binary file per home and model. Vectors are Float32 (about 1 MB for 500 × 512);
/// the file is excluded from backups and deleted with the home's search data.
public final class EmbeddingCache: VectorSource {
    public let dimension: Int
    public let modelVersion: String
    public let centersVectors: Bool
    private let state = Mutex(State())

    struct State {
        var vectors: [String: [Float]] = [:]
        var concepts: [String: [Float]] = [:]
        var dirty = false
    }

    public init(dimension: Int, modelVersion: String, centersVectors: Bool) {
        self.dimension = dimension
        self.modelVersion = modelVersion
        self.centersVectors = centersVectors
    }

    public func cachedVector(forContentHash hash: String) -> [Float]? { state.withLock { $0.vectors[hash] } }

    public func cachedConceptVectors() -> [String: [Float]] { state.withLock { $0.concepts } }

    public func store(_ vector: [Float], forContentHash hash: String) {
        guard vector.count == dimension else { return }
        state.withLock { $0.vectors[hash] = vector; $0.dirty = true }
    }

    public func storeConcept(_ vector: [Float], forType typeID: String) {
        guard vector.count == dimension else { return }
        state.withLock { $0.concepts[typeID] = vector; $0.dirty = true }
    }

    public var count: Int { state.withLock { $0.vectors.count } }

    /// Keeps only the given hashes (devices that were removed or renamed drop their vectors).
    public func retain(contentHashes: Set<String>) {
        state.withLock { current in
            let before = current.vectors.count
            current.vectors = current.vectors.filter { contentHashes.contains($0.key) }
            if current.vectors.count != before { current.dirty = true }
        }
    }

    // MARK: Persistence

    /// Format: "DSEC" | version UInt32 | dimension UInt32 | model-version length UInt32 + UTF-8 |
    /// entry count UInt32 | entries (kind UInt8: 0 device, 1 concept | key length UInt32 + UTF-8 | dimension × Float32).
    public func save(to url: URL) throws {
        let snapshot: State = state.withLock { current in
            current.dirty = false
            return current
        }
        var data = Data("DSEC".utf8)
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func appendString(_ text: String) {
            let bytes = Data(text.utf8)
            append(UInt32(bytes.count))
            data.append(bytes)
        }
        append(1)
        append(UInt32(dimension))
        appendString(modelVersion)
        append(UInt32(snapshot.vectors.count + snapshot.concepts.count))
        for (kind, entries) in [(UInt8(0), snapshot.vectors), (UInt8(1), snapshot.concepts)] {
            for (key, vector) in entries.sorted(by: { $0.key < $1.key }) {
                data.append(kind)
                appendString(key)
                for value in vector { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
            }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        Self.excludeFromBackup(url)
    }

    /// Loads a file written by `save(to:)`. Returns nil when it is missing, corrupt, or from another model.
    public static func load(from url: URL, expectedModelVersion: String, centersVectors: Bool) -> EmbeddingCache? {
        guard let data = try? Data(contentsOf: url), data.count > 16, data.prefix(4) == Data("DSEC".utf8) else { return nil }
        var offset = 4
        func readUInt32() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            var value: UInt32 = 0
            withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: data[offset..<(offset + 4)]) }
            offset += 4
            return UInt32(littleEndian: value)
        }
        func readString() -> String? {
            guard let length = readUInt32().map(Int.init), offset + length <= data.count else { return nil }
            defer { offset += length }
            return String(data: data[offset..<(offset + length)], encoding: .utf8)
        }
        guard readUInt32() == 1, let dimension = readUInt32().map(Int.init), dimension > 0,
              let model = readString(), model == expectedModelVersion,
              let count = readUInt32() else { return nil }
        let cache = EmbeddingCache(dimension: dimension, modelVersion: model, centersVectors: centersVectors)
        for _ in 0..<count {
            guard offset < data.count else { return nil }
            let kind = data[offset]
            offset += 1
            guard let key = readString(), offset + dimension * 4 <= data.count else { return nil }
            var vector = [Float](repeating: 0, count: dimension)
            for index in 0..<dimension {
                var bits: UInt32 = 0
                withUnsafeMutableBytes(of: &bits) { $0.copyBytes(from: data[(offset + index * 4)..<(offset + index * 4 + 4)]) }
                vector[index] = Float(bitPattern: UInt32(littleEndian: bits))
            }
            offset += dimension * 4
            if kind == 0 { cache.store(vector, forContentHash: key) } else { cache.storeConcept(vector, forType: key) }
        }
        cache.state.withLock { $0.dirty = false }
        return cache
    }

    public var isDirty: Bool { state.withLock { $0.dirty } }

    static func excludeFromBackup(_ url: URL) {
        #if canImport(Darwin)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
        #endif
    }
}

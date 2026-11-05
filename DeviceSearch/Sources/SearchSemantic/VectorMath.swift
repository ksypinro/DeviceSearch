import SearchCore
import SearchIndex
#if canImport(Accelerate)
import Accelerate
#endif

/// Cosine similarity over prepared (centered, unit-length) vectors (design doc §6, R12).
public enum VectorMath {
    /// Dot product of two equal-length vectors.
    public static func dot(_ a: [Float], _ b: ArraySlice<Float>) -> Float {
        var sum: Float = 0
        var index = b.startIndex
        for value in a {
            sum += value * b[index]
            index += 1
        }
        return sum
    }

    /// Scores every present row of the store against `query` with one matrix–vector product
    /// (vDSP on Apple platforms), then keeps rows at or above `minScore`, best first, at most `limit`.
    public static func topMatches(_ query: [Float], in store: VectorStore, minScore: Double,
                                  limit: Int) -> [RetrievalHit] {
        guard store.dimension > 0, query.count == store.dimension, !store.isEmpty else { return [] }
        let scores = similarities(query, store: store)
        var hits: [RetrievalHit] = []
        for ordinal in store.present.members where Double(scores[ordinal]) >= minScore {
            hits.append(RetrievalHit(document: ordinal, score: Double(scores[ordinal])))
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.document < $1.document }
        return Array(hits.prefix(limit))
    }

    /// One score per row (zero rows score 0).
    public static func similarities(_ query: [Float], store: VectorStore) -> [Float] {
        let rows = store.capacity
        let dimension = store.dimension
        var scores = [Float](repeating: 0, count: rows)
        #if canImport(Accelerate)
        store.vectors.withUnsafeBufferPointer { matrix in
            query.withUnsafeBufferPointer { vector in
                scores.withUnsafeMutableBufferPointer { output in
                    vDSP_mmul(matrix.baseAddress!, 1, vector.baseAddress!, 1, output.baseAddress!, 1,
                              vDSP_Length(rows), 1, vDSP_Length(dimension))
                }
            }
        }
        #else
        for row in 0..<rows {
            scores[row] = dot(query, store.vectors[(row * dimension)..<((row + 1) * dimension)])
        }
        #endif
        return scores
    }
}

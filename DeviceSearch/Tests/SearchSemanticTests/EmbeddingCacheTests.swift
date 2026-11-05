import Foundation
import Testing
import SearchCore
import SearchIndex
import SearchQuery
import DeviceSearch
@testable import SearchSemantic
import SearchTestSupport

@Suite("Embedding cache")
struct EmbeddingCacheTests {
    @Test func storesAndRetains() {
        let cache = EmbeddingCache(dimension: 2, modelVersion: "m", centersVectors: false)
        cache.store([1, 2], forContentHash: "a")
        cache.store([3, 4, 5], forContentHash: "bad")   // wrong dimension is ignored
        cache.store([5, 6], forContentHash: "b")
        #expect(cache.cachedVector(forContentHash: "a") == [1, 2])
        #expect(cache.count == 2)
        cache.retain(contentHashes: ["b"])
        #expect(cache.cachedVector(forContentHash: "a") == nil)
    }

    @Test func roundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = EmbeddingCache(dimension: 3, modelVersion: "model-7", centersVectors: true)
        cache.store([0.5, -1, 2], forContentHash: "abc")
        cache.storeConcept([1, 0, 0], forType: "ac")
        try cache.save(to: url)
        let loaded = EmbeddingCache.load(from: url, expectedModelVersion: "model-7", centersVectors: true)
        #expect(loaded?.cachedVector(forContentHash: "abc") == [0.5, -1, 2])
        #expect(loaded?.cachedConceptVectors()["ac"] == [1, 0, 0])
        #expect(loaded?.isDirty == false)
        #expect(EmbeddingCache.load(from: url, expectedModelVersion: "model-8", centersVectors: true) == nil)
    }
}

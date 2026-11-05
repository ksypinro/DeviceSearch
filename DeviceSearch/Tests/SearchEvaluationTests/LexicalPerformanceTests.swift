import Foundation
import Testing
import SearchCore
import SearchIndex
import DeviceSearch
@testable import SearchEvaluation
import SearchTestSupport

@Suite("Lexical performance", .serialized)
struct LexicalPerformanceTests {
    @Test func keystrokeStaysWithinOneFrameAt500Devices() async {
        let engine = SearchEngine(snapshot: TestIndex.home500)
        let queries = GoldenSetBuilder(snapshot: TestIndex.home500).build().map(\.text)
        var timings: [Duration] = []
        for query in queries {
            let start = ContinuousClock.now
            _ = await engine.topResults(for: query, limit: 20)
            timings.append(ContinuousClock.now - start)
        }
        let p95 = Metrics.percentile(timings, 95)
        print("instant p95 ms", milliseconds(p95))
        #expect(p95 <= Budget.ms(16))
    }

    @Test(arguments: [500, 5000])
    func rebuildIsFast(devices count: Int) {
        let devices = SyntheticHome.make(count: count)
        let timings = measure(5) { _ = TestIndex.builder.build(homeID: "p", devices: devices, generation: 1) }
        let best = timings.min()!
        print("rebuild \(count) ms", milliseconds(best))
        #expect(best <= Budget.ms(count == 500 ? 20 : 250))
    }

    @Test func memoryEstimateFitsTheBudget() {
        let estimate = MemoryEstimate.bytes(of: TestIndex.home500, vectorDimension: 512)
        print("memory estimate KB", estimate / 1024)
        #expect(estimate < 1_500_000 + 500 * 512 * 4)       // 1.5 MB lexical + Float32 vectors (D15)
    }
}

import SearchCore
import DeviceSearch

/// A deterministic stand-in for the language model (a port of the design doc lab's simulator). It judges type
/// fit, room, brand and word overlap from the prompt's structured copy. Use it in unit tests, SwiftUI previews,
/// the evaluation harness and on simulators without Apple Intelligence — never as the production client.
public struct SimulatedRerankClient: RerankModelClient, RewriteModelClient {
    /// Similarity between a query and a device type (0…1). Evaluation passes an embedding-based one.
    public var typeSimilarity: (@Sendable (_ query: String, _ typeID: String) -> Double)?
    public var available: Bool
    public var latency: Duration

    public init(typeSimilarity: (@Sendable (String, String) -> Double)? = nil, available: Bool = true,
                latency: Duration = .zero) {
        self.typeSimilarity = typeSimilarity
        self.available = available
        self.latency = latency
    }

    public func isAvailable() async -> Bool { available }

    public func prewarm() async {}

    public func rank(_ request: RerankModelRequest) async throws -> RerankAnswer {
        if latency > .zero { try await Task.sleep(for: latency) }
        let data = request.data
        let descriptive = data.intent == .descriptive
        let scored: [(number: Int, score: Double)] = data.rows.map { row in
            let score: Double
            if descriptive {
                let typeFit: Double
                if !data.typeIDs.isEmpty {
                    typeFit = data.typeIDs.contains(row.typeID) ? 1 : 0.6 * similarity(data.query, row.typeID)
                } else {
                    typeFit = typeSimilarity.map { $0(data.query, row.typeID) } ?? 0.5
                }
                let roomFit: Double = row.roomMatch.map { (match: Double) -> Double in
                    match >= 1 ? 1 : match >= 0.75 ? 0.8 : 0.55
                } ?? 1
                let brandFit: Double = row.brandMatch.map { (match: Bool) -> Double in match ? 1 : 0.6 } ?? 1
                score = typeFit * roomFit * brandFit + 0.1 * row.coverage
            } else {
                let typeFit: Double = data.typeIDs.isEmpty ? 0.5 : (data.typeIDs.contains(row.typeID) ? 1 : 0)
                let room: Double = row.roomMatch ?? 0.5
                let brand: Double = row.brandMatch.map { $0 ? 1.0 : 0.0 } ?? 0.5
                let placeFit: Double = (room + brand) / 2
                score = 0.6 * row.coverage + 0.25 * typeFit + 0.15 * placeFit
            }
            return (row.number, score)
        }
        let high = descriptive ? 0.6 : 0.7
        let low = descriptive ? 0.3 : 0.4
        let sorted = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.number < $1.number }
        let best = sorted.filter { $0.score >= high }.prefix(request.maxBest).map(\.number)
        let related = sorted.filter { $0.score < high && $0.score >= low }.prefix(request.maxRelated).map(\.number)
        return RerankAnswer(best: Array(best), related: Array(related))
    }

    public func chooseTypes(_ request: RewriteModelRequest) async throws -> [Int] {
        guard let typeSimilarity else { return [] }
        var scored: [(number: Int, similarity: Double)] = []
        for row in request.types {
            let similarity = typeSimilarity(request.query, row.typeID)
            if similarity >= 0.45 { scored.append((row.number, similarity)) }
        }
        scored.sort { $0.similarity != $1.similarity ? $0.similarity > $1.similarity : $0.number < $1.number }
        return scored.prefix(request.maxTypes).map(\.number)
    }

    private func similarity(_ query: String, _ typeID: String) -> Double {
        typeSimilarity?(query, typeID) ?? 0
    }
}

/// Wraps a client and corrupts its answers the way a small model can fail: an invented number, a repeated
/// number, a demoted exact match and a dropped full match (the lab's fault injection). The validator must
/// recover every one; use it in tests and QA builds.
public struct FaultInjectingClient: RerankModelClient {
    public let base: any RerankModelClient

    public init(wrapping base: any RerankModelClient) {
        self.base = base
    }

    public func isAvailable() async -> Bool { await base.isAvailable() }

    public func prewarm() async { await base.prewarm() }

    public func rank(_ request: RerankModelRequest) async throws -> RerankAnswer {
        var answer = try await base.rank(request)
        let rows = request.data.rows
        let invented = rows.count + 7
        answer.best.insert(invented, at: min(1, answer.best.count))
        if let first = answer.best.first(where: { $0 != invented }) { answer.related.insert(first, at: 0) }
        if let exact = rows.first(where: \.isExact)?.number {
            answer.best.removeAll { $0 == exact }
            answer.best.append(exact)
        }
        if let strong = rows.first(where: { row in
            !row.isExact && row.coverage >= 0.99 && (answer.best.contains(row.number) || answer.related.contains(row.number))
        })?.number {
            answer.best.removeAll { $0 == strong }
            answer.related.removeAll { $0 == strong }
        }
        return answer
    }
}

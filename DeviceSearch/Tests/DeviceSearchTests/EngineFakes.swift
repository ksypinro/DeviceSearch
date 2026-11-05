import Foundation
import Synchronization
import SearchCore
import SearchIndex
import SearchRanking
@testable import DeviceSearch

/// A thread-safe counter for fakes (Mutex is non-copyable, so it lives in a class).
final class Counter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

/// Adds every device of the given types as a "semantic" list, labelled "cooling".
struct FakeMeaning: MeaningRetrieval {
    var types: Set<String> = ["ac", "fan"]
    var delay: Duration = .zero
    let calls = Counter()

    var vectorSource: (any VectorSource)? { nil }

    func meaningLists(for query: ParsedQuery, in snapshot: IndexSnapshot, config: SearchConfig) async -> MeaningOutput? {
        calls.increment()
        if delay > .zero { try? await Task.sleep(for: delay) }
        guard query.meaningTermCount > 0 else { return nil }
        let hits = snapshot.documents.filter { types.contains($0.typeID) }
            .map { RetrievalHit(document: $0.ordinal, score: 1) }
        return MeaningOutput(lists: [RankedList(retriever: .semantic, hits: hits)], label: "cooling")
    }

    func snapshotDidChange(_ snapshot: IndexSnapshot, sink: any VectorUpdateSink) async {}
}

/// Reverses the candidate order. Can be unavailable, slow or failing.
struct FakeRefiner: ResultRefining {
    var available = true
    var delay: Duration = .zero
    var failure: RefinementFailure?
    let prewarms = Counter()

    func isAvailable() async -> Bool { available }
    func prewarm() async { prewarms.increment() }

    func refine(_ request: RefinementRequest) async throws -> RefinementOutcome {
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        let presenter = ResultPresenter(config: request.config)
        let rows = request.candidates.reversed().enumerated().map { index, candidate in
            presenter.makeResult(candidate, section: index == 0 ? .best : .related, score: 1 - Double(index) * 0.05,
                                 query: request.query, snapshot: request.snapshot, context: request.context)
        }
        return RefinementOutcome(results: rows, interventions: [], kendallTau: -1)
    }
}

/// Streams the first candidate as a partial answer, then returns the fused order.
struct StreamingFakeRefiner: ResultRefining {
    func isAvailable() async -> Bool { true }
    func prewarm() async {}

    func refine(_ request: RefinementRequest) async throws -> RefinementOutcome {
        let presenter = ResultPresenter(config: request.config)
        let rows = request.candidates.enumerated().map { index, candidate in
            presenter.makeResult(candidate, section: index == 0 ? .best : .related, score: 1 - Double(index) * 0.05,
                                 query: request.query, snapshot: request.snapshot, context: request.context)
        }
        return RefinementOutcome(results: rows, interventions: [], kendallTau: 1)
    }

    func refine(_ request: RefinementRequest,
                partial: @escaping @Sendable ([SearchResult]) async -> Void) async throws -> RefinementOutcome {
        let outcome = try await refine(request)
        await partial(Array(outcome.results.prefix(1)))
        return outcome
    }
}

/// Records selections; the next selection "learns" a nickname, usage changes priors.
actor FakePersonal: PersonalSignals {
    private(set) var selections: [SelectionRecord] = []
    private var aliases: [DeviceID: [String]] = [:]
    private var priors: [DeviceID: Double]?
    private let nickname: String

    init(nickname: String = "big screen") {
        self.nickname = nickname
    }

    nonisolated func personalList(for query: ParsedQuery, pool: Set<Int>, in snapshot: IndexSnapshot,
                                  config: SearchConfig) async -> (list: RankedList, reasons: [Int: ReasonKind])? { nil }

    func indexInputs(for devices: [DeviceRecord]) async -> PersonalIndexInputs {
        PersonalIndexInputs(priors: priors, aliases: aliases)
    }

    func recordSelection(_ selection: SelectionRecord) async -> PersonalChange {
        selections.append(selection)
        aliases[selection.device] = [nickname]
        return .aliases
    }

    func recordSettledQuery(_ text: String, at date: Date) async {}

    func recordUsage(of device: DeviceID, at date: Date) async -> PersonalChange {
        priors = [device: 1]
        return .priors
    }
}

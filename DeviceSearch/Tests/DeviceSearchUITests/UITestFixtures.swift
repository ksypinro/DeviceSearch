import Foundation
import Synchronization
import Testing
import SearchCore
import SearchIndex
import SearchRanking
import DeviceSearch
@testable import DeviceSearchUI
import SearchTestSupport

/// Wraps the real engine and records what the view model asks of it.
final class SpyEngine: DeviceSearching {
    let engine: SearchEngine
    private let log = Mutex<[String]>([])

    init(_ engine: SearchEngine) {
        self.engine = engine
    }

    var calls: [String] { log.withLock { $0 } }

    func search(_ text: String, mode: SearchMode, options: SearchOptions) -> AsyncStream<SearchSnapshot> {
        log.withLock { $0.append("search \(mode.rawValue) \(text)") }
        return engine.search(text, mode: mode, options: options)
    }

    func recordSelection(of result: SearchResult, at position: Int, in snapshot: SearchSnapshot) async {
        log.withLock { $0.append("select \(result.device.name) #\(position)") }
    }

    func prewarm() async { log.withLock { $0.append("prewarm") } }

    func searchSettled(_ text: String) async { log.withLock { $0.append("settled \(text)") } }
}

/// Reverses the candidates after a delay.
struct SlowRefiner: ResultRefining {
    var delay: Duration = .milliseconds(150)

    func isAvailable() async -> Bool { true }
    func prewarm() async {}

    func refine(_ request: RefinementRequest) async throws -> RefinementOutcome {
        try await Task.sleep(for: delay)
        let presenter = ResultPresenter(config: request.config)
        let rows = request.candidates.reversed().map {
            presenter.makeResult($0, section: .best, score: 1, query: request.query, snapshot: request.snapshot,
                                 context: request.context)
        }
        return RefinementOutcome(results: rows, interventions: [], kendallTau: -1)
    }
}

@MainActor
final class CoordinatorSpy: SearchCoordinating {
    var opened: [DeviceID] = []
    var commands: [DetectedCommand] = []
    func openDevice(_ id: DeviceID) { opened.append(id) }
    func perform(_ command: DetectedCommand) { commands.append(command) }
}

struct ScriptedVoice: VoiceTranscribing {
    var transcript: [VoiceTranscript]
    func isAvailable() async -> Bool { true }
    func transcripts() async throws -> AsyncThrowingStream<VoiceTranscript, any Error> {
        AsyncThrowingStream { continuation in
            for item in transcript { continuation.yield(item) }
            continuation.finish()
        }
    }
    func stop() async {}
}

@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
}

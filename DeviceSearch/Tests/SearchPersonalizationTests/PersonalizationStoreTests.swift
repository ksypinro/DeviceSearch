import Foundation
import Synchronization
import Testing
import SearchCore
import SearchIndex
import DeviceSearch
@testable import SearchPersonalization
import SearchTestSupport

@Suite("Personalization store")
struct PersonalizationStoreTests {
    let clock = TestClock()
    let snapshot = TestIndex.curated

    func store(directory: URL? = nil, flags: SearchFeatureFlags = .allOn) -> PersonalizationStore {
        let clock = self.clock
        return PersonalizationStore(homeID: "h", directory: directory, flags: FeatureFlagStore(flags),
                                    now: { clock.now })
    }

    func parsed(_ text: String) -> ParsedQuery {
        SearchPipeline(config: .default).parse(text, mode: .typing, options: .standard, in: snapshot)
    }

    @Test func selectionsBuildAffinityForTheQueryAndItsPrefixes() async throws {
        let store = store()
        let lamp = try #require(snapshot.documents.first { $0.device.name == "Desk Lamp" })
        _ = await store.recordSelection(selection("lamp", lamp.id, position: 4, at: clock.now))
        for typed in ["la", "lam", "lamp"] {
            let list = await store.personalList(for: parsed(typed), pool: [], in: snapshot, config: .default)
            #expect(list?.list.hits.first?.document == lamp.ordinal)
            #expect(list?.reasons[lamp.ordinal] == .usualPick)
        }
        #expect(await store.personalList(for: parsed("l"), pool: [], in: snapshot, config: .default) == nil)
        // Position weight log2(4 + 1).
        let score = await store.personalList(for: parsed("lamp"), pool: [], in: snapshot, config: .default)?.list.hits.first?.score
        #expect(abs((score ?? 0) - log2(5)) < 1e-9)
    }

    @Test func affinityFadesWithAHalfLifeOf21Days() async throws {
        let store = store()
        let lamp = try #require(snapshot.documents.first { $0.device.name == "Desk Lamp" })
        _ = await store.recordSelection(selection("lamp", lamp.id, at: clock.now))
        clock.advance(days: 21)
        let score = await store.personalList(for: parsed("lamp"), pool: [], in: snapshot, config: .default)?.list.hits.first?.score
        #expect(abs((score ?? 0) - 0.5) < 1e-9)
    }

    @Test func favoritesAmongOtherHitsJoinTheList() async throws {
        let store = store()
        let favorite = try #require(snapshot.documents.first { $0.device.usage?.isFavorite == true })
        let list = await store.personalList(for: parsed("anything"), pool: [favorite.ordinal, 0, 1], in: snapshot, config: .default)
        #expect(list?.list.hits.map(\.document).contains(favorite.ordinal) == true)
        #expect(list?.reasons[favorite.ordinal] == .favorite)
    }

    @Test func usageRaisesPriors() async throws {
        let store = store()
        let devices = snapshot.documents.map(\.device)
        let target = devices[7].id
        #expect(await store.recordUsage(of: target, at: clock.now) == .priors)
        let priors = try #require(await store.indexInputs(for: devices).priors)
        #expect(priors[target]! >= 0.7)
        #expect(priors.filter { $0.key != target }.values.allSatisfy { $0 <= 0.3 + 1e-9 })   // only favorites
    }

    @Test func withoutLocalHistoryPriorsUseBackendCounts() async {
        let devices = snapshot.documents.map(\.device)
        let fromStore = await store().indexInputs(for: devices).priors
        #expect(fromStore == UsagePriorProvider().priors(for: devices))
    }

    @Test func threeUnexplainedPicksLearnANickname() async {
        let store = store()
        let tv = DeviceID("c-living-tv")
        #expect(await store.recordSelection(selection("big screen", tv, lexical: false, at: clock.now)) == [])
        #expect(await store.recordSelection(selection("big screen", tv, lexical: true, at: clock.now)) == [])
        #expect(await store.recordSelection(selection("big screen", tv, lexical: false, at: clock.now)) == [])
        #expect(await store.recordSelection(selection("big screen", tv, lexical: false, at: clock.now)) == .aliases)
        #expect(await store.learnedNicknames() == [tv: ["big screen"]])
        #expect(await store.indexInputs(for: []).aliases == [tv: ["big screen"]])
    }

    @Test func removedNicknamesAreNeverRelearned() async {
        let store = store()
        let tv = DeviceID("c-living-tv")
        for _ in 0..<3 { _ = await store.recordSelection(selection("big screen", tv, lexical: false, at: clock.now)) }
        #expect(await store.removeNickname("big screen", for: tv) == .aliases)
        for _ in 0..<5 { _ = await store.recordSelection(selection("big screen", tv, lexical: false, at: clock.now)) }
        #expect(await store.learnedNicknames().isEmpty)
    }

    @Test func nicknameFlagStopsLearning() async {
        var flags = SearchFeatureFlags.allOn
        flags.nicknamesEnabled = false
        let store = store(flags: flags)
        for _ in 0..<3 { _ = await store.recordSelection(selection("big screen", "c-living-tv", lexical: false, at: clock.now)) }
        #expect(await store.learnedNicknames().isEmpty)
    }

    @Test func persistsPerHomeAndClears() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = store(directory: directory)
        _ = await first.recordUsage(of: "d1", at: clock.now)
        for _ in 0..<3 { _ = await first.recordSelection(selection("big screen", "d1", lexical: false, at: clock.now)) }
        let file = directory.appendingPathComponent("personalization.json")
        #expect(FileManager.default.fileExists(atPath: file.path))

        let reopened = store(directory: directory)
        #expect(await reopened.learnedNicknames() == ["d1": ["big screen"]])
        await reopened.clear()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await reopened.learnedNicknames().isEmpty)
    }
}

@Suite("Reformulation misses")
struct ReformulationMissTests {
    @Test func missesAreKeptThirtyDays() async {
        let clock = TestClock()
        let telemetry = InMemoryTelemetry()
        let store = PersonalizationStore(homeID: "h", directory: nil, telemetry: telemetry, now: { clock.now })
        await store.recordSettledQuery("big screan", at: clock.now)
        clock.advance(seconds: 2)
        await store.recordSettledQuery("tv", at: clock.now)
        #expect(await store.reformulationMisses(since: .distantPast).map(\.queryKey) == ["big screan"])
        #expect(telemetry.events.contains(.reformulationMiss))
        clock.advance(days: 31)
        await store.recordSettledQuery("lamp", at: clock.now)
        clock.advance(seconds: 1)
        await store.recordSettledQuery("light", at: clock.now)
        #expect(await store.reformulationMisses(since: .distantPast).map(\.queryKey) == ["lamp"])
    }
}

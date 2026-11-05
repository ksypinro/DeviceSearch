import Foundation
import Testing
import SearchCore
import SearchIndex
@testable import DeviceSearch
import SearchTestSupport

/// Polls until the engine's snapshot generation passes `generation` (at most 5 s; tests run in parallel).
func waitForGeneration(_ engine: SearchEngine, after generation: UInt64) async {
    for _ in 0..<250 {
        if await engine.currentSnapshot.generation > generation { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

@Suite("Index sync")
struct IndexSyncTests {
    func makeHome(_ devices: [DeviceRecord] = SyntheticHome.curated) async -> HomeSearch {
        var config = SearchConfig.default
        config.rebuildCoalescing = .milliseconds(20)
        return await HomeSearch.make(homeID: "home", devices: devices,
                                     components: DeviceSearchComponents(knowledge: TestIndex.knowledge, config: config))
    }

    @Test func coalescesBurstsIntoOneRebuild() async throws {
        let home = await makeHome()
        let before = await home.engine.currentSnapshot.generation
        for index in 0..<5 {
            await home.sync.apply(.upserted(DeviceRecord(id: DeviceID("new\(index)"), name: "Studio Lamp \(index)",
                                                         manufacturer: "IKEA", type: "light", room: "Studio")))
        }
        await waitForGeneration(home.engine, after: before)
        try await Task.sleep(for: .milliseconds(100))      // no second rebuild follows
        let after = await home.engine.currentSnapshot
        #expect(after.generation == before + 1)
        #expect(after.count == 48 + 5)
        let results = await home.engine.searchAll("studio lamp 3", mode: .submitted).last!
        #expect(results.results.first?.device.name == "Studio Lamp 3")
    }

    @Test func statusChangesTakeTheFastPath() async {
        let home = await makeHome()
        let generation = await home.engine.currentSnapshot.generation
        await home.sync.apply(.statusChanged("d001", DeviceStatus(isOnline: false, isOn: false)))
        let snapshot = await home.engine.currentSnapshot
        #expect(snapshot.generation == generation)
        #expect(snapshot.facets.offline.contains(snapshot.ordinal(of: "d001")!))
        let offline = await home.engine.searchAll("offline ac", mode: .submitted).last!
        #expect(offline.results.contains { $0.device.name == "Bedroom AC" })
    }

    @Test func renamesAndRemovalsRebuild() async {
        let home = await makeHome()
        var renamed = SyntheticHome.curated[0]
        renamed.name = "Sleep Cooler"
        await home.sync.apply(.upserted(renamed))
        await home.sync.apply(.removed("d002"))
        await home.sync.rebuildNow()
        let snapshot = await home.engine.currentSnapshot
        #expect(snapshot.document(for: "d001")?.device.name == "Sleep Cooler")
        #expect(snapshot.document(for: "d002") == nil)
    }

    @Test func snapshotUpdatesStreamPublishesNewGenerations() async {
        let home = await makeHome()
        var iterator = await home.engine.snapshotUpdates().makeAsyncIterator()
        let first = await iterator.next()
        await home.sync.apply(.removed("d003"))
        await home.sync.rebuildNow()
        let second = await iterator.next()
        #expect((second?.generation ?? 0) > (first?.generation ?? 0))
    }
}

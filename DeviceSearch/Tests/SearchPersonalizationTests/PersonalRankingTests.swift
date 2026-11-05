import Foundation
import Synchronization
import Testing
import SearchCore
import SearchIndex
import DeviceSearch
@testable import SearchPersonalization
import SearchTestSupport

@Suite("Personal ranking end to end")
struct PersonalRankingTests {
    @Test func yourUsualPickWinsANearTie() async throws {
        // No favorites and no usage, so only the person's picks separate the two.
        let devices = [
            DeviceRecord(id: "a", name: "Front Door", manufacturer: "August", type: "lock"),
            DeviceRecord(id: "b", name: "Front Doorbell", manufacturer: "Ring", type: "doorbell"),
            DeviceRecord(id: "c", name: "Kitchen Light", manufacturer: "IKEA", type: "light"),
        ]
        let store = PersonalizationStore(homeID: "h", directory: nil)
        let home = await HomeSearch.make(homeID: "h", devices: devices,
                                         components: DeviceSearchComponents(knowledge: TestIndex.knowledge, personal: store))
        let before = await home.engine.searchAll("front", mode: .typing)
        #expect(before[0].results.prefix(2).map(\.device.name) == ["Front Door", "Front Doorbell"])
        let doorbell = before[0].results[1]
        for _ in 0..<2 { await home.engine.recordSelection(of: doorbell, at: 2, in: before[0]) }
        let after = await home.engine.searchAll("front", mode: .typing)
        #expect(after[0].results.first?.id == doorbell.id)
        #expect(after[0].results.first?.reasons.contains { $0.kind == .usualPick } == true)
        // A longer query that starts with the past one still knows the pick.
        let longer = await home.engine.searchAll("front do", mode: .typing)
        #expect(longer[0].results.first?.id == doorbell.id)
    }

    @Test func strongNameMatchesStillLeadSetQueries() async throws {
        let store = PersonalizationStore(homeID: "h", directory: nil)
        let home = await HomeSearch.make(homeID: "h", devices: SyntheticHome.curated,
                                         components: DeviceSearchComponents(knowledge: TestIndex.knowledge, personal: store))
        let before = await home.engine.searchAll("lamp", mode: .submitted)
        let last = try #require(before[0].results.indices.last)
        let pick = before[0].results[last]
        for _ in 0..<2 { await home.engine.recordSelection(of: pick, at: last + 1, in: before[0]) }
        let after = await home.engine.searchAll("lamp", mode: .submitted)
        let moved = try #require(after[0].results.firstIndex { $0.id == pick.id })
        #expect(moved < last)                                            // it rises…
        #expect(after[0].results.count == before[0].results.count)       // …and nothing is hidden (§15)
    }

    @Test func aLearnedNicknameBecomesAnExactMatch() async throws {
        let store = PersonalizationStore(homeID: "h", directory: nil)
        var config = SearchConfig.default
        config.rebuildCoalescing = .milliseconds(10)
        let home = await HomeSearch.make(homeID: "h", devices: SyntheticHome.curated,
                                         components: DeviceSearchComponents(knowledge: TestIndex.knowledge, config: config,
                                                                            personal: store))
        let snapshot = await home.engine.currentSnapshot
        let tv = try #require(snapshot.documents.first { $0.typeID == "tv" })
        let search = await home.engine.searchAll("big screen", mode: .submitted)
        // The person found the TV through meaning only (no lexical evidence) and picked it three times.
        let picked = SearchResult(device: tv.device, typeLabel: tv.typeCard.label, typeCode: tv.typeCard.code,
                                  section: .related, score: 0.5, evidence: [.semantic], document: tv.ordinal)
        for _ in 0..<3 { await home.engine.recordSelection(of: picked, at: 2, in: search[0]) }
        for _ in 0..<100 where await home.engine.currentSnapshot.generation == 1 { try await Task.sleep(for: .milliseconds(20)) }
        let after = await home.engine.searchAll("big screen", mode: .submitted)
        #expect(after[0].results.first?.id == tv.id)
        #expect(after[0].results.first?.reasons.first?.kind == .exactName)
    }
}

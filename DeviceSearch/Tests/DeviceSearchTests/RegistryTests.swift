import Foundation
import Testing
import SearchCore
import SearchIndex
@testable import DeviceSearch
import SearchTestSupport

@Suite("Registry")
struct RegistryTests {
    @Test func oneSearchPerHome() async {
        let registry = SearchEngineRegistry(components: DeviceSearchComponents(knowledge: TestIndex.knowledge))
        let first = await registry.open("a", devices: SyntheticHome.curated)
        let again = await registry.open("a", devices: [])
        #expect(first.engine === again.engine)
        await registry.open("b", devices: Array(SyntheticHome.curated.prefix(5)))
        #expect(await registry.openHomes == ["a", "b"])
        await registry.close("a")
        #expect(await registry.openHomes == ["b"])
        #expect(await registry.search(for: "a") == nil)
    }

    @Test func eachHomeGetsItsOwnComponents() async {
        let made = Counter()
        let registry = SearchEngineRegistry { _ in
            made.increment()
            return DeviceSearchComponents(knowledge: TestIndex.knowledge, personal: FakePersonal())
        }
        await registry.open("a", devices: SyntheticHome.curated)
        await registry.open("b", devices: SyntheticHome.curated)
        await registry.open("a", devices: SyntheticHome.curated)
        #expect(made.count == 2)
    }
}

@Suite("Personal signal wiring")
struct PersonalWiringTests {
    @Test func aLearnedNicknameTriggersARebuild() async throws {
        let personal = FakePersonal()
        let home = await HomeSearch.make(homeID: "h", devices: SyntheticHome.curated,
                                         components: DeviceSearchComponents(knowledge: TestIndex.knowledge, personal: personal))
        let before = await home.engine.searchAll("Living Room TV", mode: .submitted)
        let tv = try #require(before[0].results.first)
        await home.engine.recordSelection(of: tv, at: 1, in: before[0])
        #expect(await personal.selections.first?.hadLexicalEvidence == true)
        await waitForGeneration(home.engine, after: 1)
        let after = await home.engine.searchAll("big screen", mode: .submitted)
        #expect(after[0].results.first?.id == tv.id)
        #expect(after[0].results.first?.reasons.first?.kind == .exactName)   // nicknames count as exact (R02)
    }

    @Test func usageUpdatesPriorsInPlace() async {
        let personal = FakePersonal()
        let home = await HomeSearch.make(homeID: "h", devices: SyntheticHome.curated,
                                         components: DeviceSearchComponents(knowledge: TestIndex.knowledge, personal: personal))
        let device = SyntheticHome.curated[5].id
        await home.engine.recordUsage(of: device)
        let snapshot = await home.engine.currentSnapshot
        #expect(snapshot.document(for: device)?.prior == 1)
        #expect(snapshot.generation == 1)                           // no rebuild
    }
}

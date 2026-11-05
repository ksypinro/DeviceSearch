import Testing
import SearchCore
import SearchTestSupport

@Suite("Synthetic homes")
struct SyntheticHomeTests {
    @Test func homesAreDeterministic() {
        #expect(SyntheticHome.make(count: 500).map(\.name) == SyntheticHome.make(count: 500).map(\.name))
    }

    @Test func idsAreUniqueAndOrdered() {
        let home = SyntheticHome.make(count: 500)
        #expect(home.count == 500)
        #expect(home.first?.id == "d001")
        #expect(Set(home.map(\.id)).count == 500)
    }

    @Test func theCuratedHomeOpensTheLabHome() {
        #expect(SyntheticHome.curated.count == 48)
        #expect(SyntheticHome.curated.first?.name == "Bedroom AC")
        #expect(SyntheticHome.make(count: 500).prefix(48).map(\.name) == SyntheticHome.curated.map(\.name))
    }
}

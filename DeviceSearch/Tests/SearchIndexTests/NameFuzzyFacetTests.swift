import Testing
import SearchCore
import SearchText
@testable import SearchIndex

@Suite("Name, fuzzy and facet indexes (direct)")
struct NameFuzzyFacetTests {
    let documents = IndexFixtures.documents()

    @Test func exactNamesUseBothFormsAndNicknames() {
        let names = NameIndex(documents: documents, pipeline: IndexFixtures.pipeline, aliases: [1: ["big screen"]])
        #expect(names.documents(named: "bedroom ac") == [0])
        #expect(names.documents(named: "living room tv") == [1])
        #expect(names.documents(named: "livingroomtv") == [1])
        #expect(names.documents(named: "big screen") == [1])
    }

    @Test func fuzzyPostings() {
        let fuzzy = FuzzyIndex(documents: documents, encoder: MetaphoneLite())
        #expect(fuzzy.documents(withTrigram: "$li").contains(1))
        #expect(fuzzy.documents(withPhoneticKey: "SMSNK") == [0])
    }

    @Test func missingStatusIsNoSignal() {
        let facets = FacetIndex(documents: documents)
        #expect(facets.members(.offline).members == [2])
        #expect(facets.members(.online).members == [0, 1])
        #expect(facets.members(.on).members == [0])
        #expect(facets.members(.off).members == [1])
        #expect(!facets.online.contains(3) && !facets.offline.contains(3))
    }

    @Test func typeBrandAndRoomSets() {
        let facets = FacetIndex(documents: documents)
        #expect(facets.types["ac"]?.members == [0])
        #expect(facets.brands["samsung"]?.members == [0])
        #expect(facets.rooms["living-room"]?.members == [1])
    }
}

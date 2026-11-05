import Testing
import SearchCore
import SearchKnowledge
@testable import SearchIndex
import SearchTestSupport

@Suite("Search documents")
struct SearchDocumentTests {
    let snapshot = TestIndex.tiny

    @Test func nameTokensIncludeSplitAndUnsplitForms() {
        let tv = snapshot.document(for: "t2")!
        #expect(tv.nameTokens == ["living", "room", "tv", "livingroomtv"])
        #expect(tv.compactKey == "livingroomtv")
    }

    @Test func fieldsCarryInternalEntityTokens() {
        let ac = snapshot.document(for: "t1")!
        #expect(ac.fieldTokens[.type]!.contains("aircon"))
        #expect(ac.fieldTokens[.type]!.last == "§t:ac")
        #expect(ac.fieldTokens[.brand]!.last == "§b:samsung")
        #expect(ac.fieldTokens[.room]!.last == "§r:bedroom")
        #expect(!ac.allTokens.contains("§t:ac"))
        #expect(ac.allTokens.contains("samsung"))
    }

    @Test func roomsResolveToTheLexiconOrAdHoc() {
        let tv = snapshot.document(for: "t2")!
        #expect(tv.roomID == "living-room")                     // "Lounge" is an alias of Living Room
        #expect(tv.fieldTokens[.room]!.contains("lounge"))
        #expect(tv.fieldTokens[.room]!.contains("living"))      // canonical name tokens are added
        let lamp = snapshot.document(for: "t3")!
        #expect(lamp.roomID == "room-ayaan-room")
        #expect(lamp.brandID == "x-acme-gadget")
    }

    @Test func embeddingTextIsEnriched() {
        let ac = snapshot.document(for: "t1")!
        #expect(ac.embeddingText == "Bedroom AC. Air Conditioner (aircon, air con, air conditioner). Samsung. In Bedroom.")
    }

    @Test func roomMatchIsExactOrPartial() {
        let master = TestIndex.home500.documents.first { $0.room?.id == "master-bedroom" }!
        #expect(master.roomMatch(id: "master-bedroom", tokens: ["master", "bedroom"]) == 1)
        #expect(master.roomMatch(id: "bedroom", tokens: ["bedroom"]) == 0.75)
        #expect(master.roomMatch(id: "kitchen", tokens: ["kitchen"]) == 0)
    }

    @Test func priorsComeFromUsage() {
        #expect(snapshot.document(for: "t1")!.prior == 1.0)   // most used and favorite
        #expect(snapshot.document(for: "t2")!.prior == 0)
    }
}

@Suite("Inverted index and vocabulary")
struct InvertedIndexTests {
    let snapshot = TestIndex.tiny

    @Test func postingsAreSortedOrdinals() {
        #expect(snapshot.inverted.documents(containing: "bedroom") == [0])
        #expect(snapshot.inverted.documents(containing: "§t:ac") == [0])
        #expect(snapshot.inverted.documentFrequency("nothing") == 0)
    }

    @Test func idfFollowsBM25() {
        // N = 4, df = 1 → ln(1 + 3.5 / 1.5)
        #expect(abs(snapshot.inverted.idf("samsung") - 1.2039728) < 1e-6)
    }

    @Test func vocabularyWeights() {
        let vocabulary = snapshot.vocabulary
        #expect(vocabulary.frequency(of: "bedroom") == 1)
        #expect(vocabulary.frequency(of: "thermostat") == 0.5)   // knowledge base only
        #expect(vocabulary.frequency(of: "intruder") == 0.25)    // meaning lexicon only
        #expect(!vocabulary.contains("2"))
        #expect(vocabulary.nameTerms.contains("ayaan"))
    }

    @Test func completionsPreferFrequentShortTerms() {
        let completions = TestIndex.home500.vocabulary.completions(for: "bed", limit: 3)
        #expect(completions.first == "bedroom")
        #expect(!completions.contains("bed"))
    }
}

@Suite("Name, fuzzy and facet indexes")
struct FacetIndexTests {
    let snapshot = TestIndex.tiny

    @Test func exactNamesUseBothForms() {
        #expect(snapshot.names.documents(named: "bedroom ac") == [0])
        #expect(snapshot.names.documents(named: "living room tv") == [1])
        #expect(snapshot.names.documents(named: "livingroomtv") == [1])
    }

    @Test func fuzzyPostings() {
        #expect(snapshot.fuzzy.documents(withTrigram: "$li").contains(1))
        #expect(snapshot.fuzzy.documents(withPhoneticKey: "SMSNK") == [0])
    }

    @Test func statusSetsTreatMissingStatusAsNoSignal() {
        let facets = snapshot.facets
        #expect(facets.members(.offline).members == [2])
        #expect(facets.members(.online).members == [0, 1])
        #expect(facets.members(.on).members == [0])
        #expect(facets.members(.off).members == [1])
        // "Front Door" has no status: in no live-state set.
        #expect(!facets.online.contains(3) && !facets.offline.contains(3))
    }

    @Test func roomEntitiesMatchExactlyOrByContainedWords() {
        let home = TestIndex.home500
        let bedroom = QueryEntity(kind: .room, id: "bedroom", label: "Bedroom", words: "bedroom", roomTokens: ["bedroom"])
        let exact = home.facets.members(of: bedroom)
        #expect(exact.members.allSatisfy { home.documents[$0].roomID == "bedroom" })
        // In a home without a plain "Bedroom", the same entity matches rooms containing the word.
        let noPlainBedroom = TestIndex.snapshot(SyntheticHome.make(count: 500).filter { $0.room != "Bedroom" })
        let partial = noPlainBedroom.facets.members(of: bedroom)
        #expect(!partial.isEmpty)
        #expect(partial.members.contains { noPlainBedroom.documents[$0].roomID == "master-bedroom" })
    }

    @Test func combinedFacetAlgebra() {
        let home = TestIndex.home500
        let light = QueryEntity(kind: .type, id: "light", label: "Light", words: "lights")
        let kitchen = QueryEntity(kind: .room, id: "kitchen", label: "Kitchen", words: "kitchen", roomTokens: ["kitchen"])
        let lightsExceptKitchen = home.facets.members(types: [light], brands: [], rooms: [], network: nil, power: nil,
                                                      excluded: [kitchen])
        #expect(!lightsExceptKitchen.isEmpty)
        #expect(lightsExceptKitchen.members.allSatisfy { home.documents[$0].typeID == "light" && home.documents[$0].roomID != "kitchen" })
    }
}

@Suite("Snapshot and builder")
struct SnapshotTests {
    @Test func homeRoomsAndBrandsJoinThePhraseDictionary() {
        let snapshot = TestIndex.tiny
        #expect(snapshot.phrases.entries(forKey: "ayaan room").first?.id == "room-ayaan-room")
        #expect(snapshot.phrases.entries(forKey: "acme gadget").first?.id == "x-acme-gadget")
    }

    @Test func statusFastPathUpdatesDocumentsAndBitsets() {
        let updated = TestIndex.tiny.updatingStatus(DeviceStatus(isOnline: true, isOn: true), for: "t3")!
        #expect(updated.facets.online.contains(2))
        #expect(!updated.facets.offline.contains(2))
        #expect(updated.document(for: "t3")!.device.status?.isOnline == true)
        #expect(TestIndex.tiny.updatingStatus(nil, for: "missing") == nil)
    }

    @Test func priorsCanBeReplaced() {
        let updated = TestIndex.tiny.updatingPriors(["t2": 0.9, "t9": 1])
        #expect(updated.document(for: "t2")!.prior == 0.9)
    }

    @Test func buildsTheLabHome() {
        let home = TestIndex.home500
        #expect(home.count == 500)
        #expect(home.document(for: "d001")?.device.name == "Bedroom AC")
        #expect(home.vectors.isEmpty)
    }

    @Test func vectorSourceFillsVectorsAtBuildTime() {
        struct FakeSource: VectorSource {
            var dimension: Int { 2 }
            var modelVersion: String { "fake-1" }
            var centersVectors: Bool { false }
            func cachedVector(forContentHash hash: String) -> [Float]? { [3, 4] }
            func cachedConceptVectors() -> [String: [Float]] { ["ac": [1, 0]] }
        }
        let snapshot = TestIndex.builder.build(homeID: "h", devices: SyntheticHome.curated, vectorSource: FakeSource())
        #expect(snapshot.vectors.warmedCount == 48)
        #expect(snapshot.vectors.vector(at: 0).map(Array.init) == [0.6, 0.8])
        #expect(snapshot.concepts.typeIDs == ["ac"])
    }
}

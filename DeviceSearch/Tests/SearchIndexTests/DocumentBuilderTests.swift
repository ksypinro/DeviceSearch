import Testing
import SearchCore
@testable import SearchIndex

@Suite("Document builder")
struct DocumentBuilderTests {
    let documents = IndexFixtures.documents()

    @Test func camelCaseNamesKeepBothForms() {
        let tv = documents[1]
        #expect(tv.nameTokens == ["living", "room", "tv", "livingroomtv"])
        #expect(tv.nameKeys == ["living room tv", "livingroomtv"])
        #expect(tv.compactKey == "livingroomtv")
    }

    @Test func plainNamesHaveOneKey() {
        #expect(documents[0].nameKeys == ["bedroom ac"])
    }

    @Test func fieldsEndWithInternalEntityTokens() {
        let ac = documents[0]
        #expect(ac.fieldTokens[.type]!.contains("aircon"))
        #expect(ac.fieldTokens[.type]!.last == "§t:ac")
        #expect(ac.fieldTokens[.brand]!.last == "§b:samsung")
        #expect(ac.fieldTokens[.room]!.last == "§r:bedroom")
        #expect(!ac.allTokens.contains("§t:ac"))
        #expect(ac.allTokens.contains("samsung"))
    }

    @Test func embeddingTextIsEnriched() {
        #expect(documents[0].embeddingText == "Bedroom AC. Air Conditioner (aircon, air con, air conditioner). Samsung. In Bedroom.")
    }

    @Test func devicesOfATypeShareTheTypeField() {
        let twoACs = IndexFixtures.documents([
            DeviceRecord(id: "a", name: "Office AC", manufacturer: "LG", type: "ac"),
            DeviceRecord(id: "b", name: "Den AC", manufacturer: "Daikin", type: "ac"),
        ])
        #expect(twoACs[0].fieldTokens[.type] == twoACs[1].fieldTokens[.type])
        #expect(twoACs[0].termFrequencies[.type] == twoACs[1].termFrequencies[.type])
        #expect(twoACs[0].termFrequencies[.type]?["§t:ac"] == 1)
    }

    @Test func contentHashFollowsTheDevice() {
        #expect(documents[2].contentHash == IndexFixtures.devices[2].contentHash)
    }
}

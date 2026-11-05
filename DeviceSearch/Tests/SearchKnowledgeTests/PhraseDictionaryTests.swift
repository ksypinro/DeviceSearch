import Testing
import SearchCore
@testable import SearchKnowledge

@Suite("Phrase dictionary")
struct PhraseDictionaryTests {
    let kb = try! KnowledgeBase.bundled()
    var phrases: PhraseDictionary { PhraseDictionary(knowledge: kb, pipeline: kb.makePipeline()) }

    @Test func typeSynonymsAndPlurals() {
        #expect(phrases.entries(forKey: "aircon").map(\.id) == ["ac"])
        #expect(phrases.entries(forKey: "air con").map(\.id) == ["ac"])
        #expect(phrases.entries(forKey: "light").map(\.id) == ["light"])   // "lights" stems to "light"
        #expect(phrases.entries(forKey: "এসি").map(\.id) == ["ac"])
    }

    @Test func aliasMayNameSeveralBrands() {
        #expect(Set(phrases.entries(forKey: "philips").map(\.id)) == ["philips-hue", "philips"])
        #expect(phrases.entries(forKey: "hue").map(\.id) == ["philips-hue"])
    }

    @Test func longestMatchWins() {
        let terms = ["not", "responding", "camera"]
        let match = phrases.longestMatch(in: terms, from: 0)
        #expect(match?.length == 2)
        #expect(match?.entries.first?.kind == .status)
        #expect(phrases.longestMatch(in: ["not", "kitchen"], from: 0)?.entries.first?.kind == .negation)
    }

    @Test func roomsCarryTokensOfTheirName() {
        let lounge = phrases.entries(forKey: "lounge").first
        #expect(lounge?.id == "living-room")
        #expect(lounge?.roomTokens == ["living", "room"])
    }

    @Test func functionAndEntityTokens() {
        #expect(phrases.isFunctionToken("the"))
        #expect(phrases.isFunctionToken("on"))
        #expect(phrases.isFunctionToken("responding"))
        #expect(!phrases.isFunctionToken("light"))
        #expect(phrases.entityTokens.contains("aircon"))
    }

    @Test func homeRoomsCanBeAdded() {
        var dictionary = phrases
        dictionary.addRoom(id: "room-ayaan-room", label: "Ayaan's Room", names: ["Ayaan's Room"])
        #expect(dictionary.entries(forKey: "ayaan room").first?.id == "room-ayaan-room")
    }
}

import Testing
import SearchCore
import SearchIndex
@testable import SearchQuery
import SearchTestSupport

@Suite("Entities and intent")
struct IntentTests {
    let parser = QueryParser()
    let home = TestIndex.home500

    @Test(arguments: [
        ("bedroom ac", QueryIntent.compound),
        ("lights", .categorical),
        ("all lights", .categorical),
        ("lights except kitchen", .categorical),
        ("offline cameras", .categorical),
        ("aircon in guest room", .compound),
        ("something to cool the bedroom", .descriptive),
        ("movie night", .descriptive),
        ("tv 2", .navigational),
        ("bob lamp", .navigational),
        ("turn off hallway lights", .command),
        ("turn off the bedroom", .command),
        ("play music in the kitchen", .descriptive),
        ("detect movement in the hallway", .descriptive),
        ("fresh air in the bedroom", .descriptive),
        ("check who is at the door", .descriptive),
        ("the room feels stuffy", .descriptive),
        ("front door", .navigational),
        ("", .empty),
    ])
    func classifies(raw: String, intent: QueryIntent) {
        #expect(parser.parse(raw, mode: .submitted, in: home).intent == intent)
    }

    @Test func negationAppliesToTheNextEntityOnly() {
        let query = parser.parse("lights except kitchen", mode: .submitted, in: home)
        #expect(query.entities.map(\.id) == ["light"])
        #expect(query.excluded.map(\.id) == ["kitchen"])
        #expect(query.flags.plural)
        #expect(query.hard.excluded.map(\.id) == ["kitchen"])
    }

    @Test func statusPhraseBeatsNegation() {
        let query = parser.parse("not responding cameras", mode: .submitted, in: home)
        #expect(query.network == .offline)
        #expect(query.excluded.isEmpty)
    }

    @Test func roomPrepositionMakesARoomHardEvenForNavigationalQueries() {
        let query = parser.parse("bob lamp in guest room", mode: .submitted, in: home)
        #expect(query.intent == .navigational)
        #expect(query.hard.rooms.map(\.id) == ["guest-room"])
        #expect(query.hard.types.isEmpty)
    }

    @Test func entitiesAreBoostsUnlessTheUserSignalsASet() {
        let navigational = parser.parse("kitchen light 2", mode: .submitted, in: home)
        #expect(navigational.intent == .navigational)
        #expect(navigational.hard.isEmpty)
        let set = parser.parse("kitchen lights", mode: .submitted, in: home)
        #expect(set.hard.types.map(\.id) == ["light"])
        #expect(set.hard.rooms.map(\.id) == ["kitchen"])
    }

    /// The design doc's ParsedQuery example (§5). By the doc's own rules an exclusion makes it categorical
    /// (the example says compound); both are set intents with identical behaviour.
    @Test func designDocExample() {
        let query = parser.parse("samsng ac in guest room except offline", mode: .submitted, in: home)
        #expect(query.tokens == ["samsng", "ac", "in", "guest", "room", "except", "offline"])
        #expect(query.corrections == [Correction(from: "samsng", to: "samsung", method: .edit, cost: 1, confidence: 0.7)])
        #expect(query.entities.map { "\($0.kind.rawValue):\($0.id)" } == ["brand:samsung", "type:ac", "room:guest-room"])
        #expect(query.excluded.map(\.id) == ["offline"])
        #expect(query.flags.roomPreposition)
        #expect(query.intent == .categorical)
        #expect(query.intent.isSet)
        #expect(query.hard.brands.map(\.id) == ["samsung"])
        #expect(query.hard.rooms.map(\.id) == ["guest-room"])
    }

    @Test func onOrOffBeforeAMeaningWordIsNotAPowerState() {
        #expect(parser.parse("is anything on fire", mode: .submitted, in: home).power == nil)
        #expect(parser.parse("lights that are on", mode: .submitted, in: home).power == .on)
        #expect(parser.parse("lights on in the kitchen", mode: .submitted, in: home).power == .on)
    }

    @Test(arguments: ["watch the news", "monitor the baby while sleeping", "the room feels stuffy",
                      "who rang the bell", "air quality in the bedroom", "need more heat", "darken the bedroom"])
    func everydayWordsAreNotCorrected(raw: String) {
        #expect(parser.parse(raw, mode: .submitted, in: home).corrections.isEmpty)
    }

    @Test func meaningWordsOfADescriptiveQueryStopBeingNames() throws {
        let query = parser.parse("check who is at the door", mode: .submitted, in: home)
        let marked = try #require(parser.describingNeeds(query, in: home))
        #expect(marked.nameTerms.filter(\.describesNeed).map(\.term) == ["door"])
        #expect(marked.typedKey.isEmpty)
        #expect(!marked.highlightTerms.contains("door"))
        // Entity words stay names, and other intents are left alone.
        let room = try #require(parser.describingNeeds(parser.parse("fresh air in the bedroom", mode: .submitted, in: home), in: home))
        #expect(room.nameTerms.filter { !$0.describesNeed }.map(\.term) == ["bedroom"])
        #expect(parser.describingNeeds(parser.parse("front door", mode: .submitted, in: home), in: home) == nil)
    }

    @Test func keysForMatching() {
        let query = parser.parse("Living Room TV", mode: .submitted, in: home)
        #expect(query.typedKey == "livingroomtv")
        #expect(query.cleanKey == "living room tv")
        #expect(query.sequenceAll == "living room tv")
        #expect(query.highlightTerms == ["living", "room", "tv"])
    }
}

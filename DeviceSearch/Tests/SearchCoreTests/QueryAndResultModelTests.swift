import Testing
@testable import SearchCore

@Suite("Query, retrieval and result models")
struct QueryAndResultModelTests {
    @Test func setIntents() {
        #expect(QueryIntent.categorical.isSet && QueryIntent.compound.isSet && QueryIntent.command.isSet)
        #expect(!QueryIntent.navigational.isSet && !QueryIntent.descriptive.isSet && !QueryIntent.empty.isSet)
    }

    @Test func entityTokens() {
        #expect(QueryEntity(kind: .type, id: "ac", label: "Air Conditioner", words: "aircon").specialToken == "§t:ac")
        #expect(QueryEntity(kind: .brand, id: "lg", label: "LG", words: "lg").specialToken == "§b:lg")
        #expect(QueryEntity(kind: .room, id: "kitchen", label: "Kitchen", words: "kitchen").specialToken == "§r:kitchen")
        #expect(QueryEntity(kind: .status, id: "offline", label: "Offline", words: "offline").specialToken == nil)
        #expect(QueryEntity(kind: .status, id: "offline", label: "Offline", words: "offline").statusCondition == .offline)
    }

    @Test func evidenceComesFromContributions() {
        var candidate = FusedCandidate(document: 3)
        candidate.contributions[.prefix] = 0.1
        #expect(candidate.evidence == [.prefix])
        #expect(candidate.has(.prefix) && !candidate.has(.semantic))
    }

    @Test func lexicalRetrievers() {
        #expect(RetrieverID.exact.isLexical && RetrieverID.facets.isLexical)
        #expect(!RetrieverID.semantic.isLexical && !RetrieverID.concept.isLexical && !RetrieverID.personal.isLexical)
    }

    @Test func sectionTitles() {
        #expect(ResultSection.best.title == "Best matches")
        #expect(ResultSection.other.title == "Other matches")
    }
}

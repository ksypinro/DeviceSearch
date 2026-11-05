import Testing
import SearchCore
@testable import SearchKnowledge

@Suite("Knowledge base")
struct KnowledgeBaseTests {
    let kb = try! KnowledgeBase.bundled()

    @Test func loadsBundledResources() {
        #expect(kb.types.count == 34)
        #expect(kb.brands.count == 79)
        #expect(kb.rooms.count == 26)
        #expect(kb.version == "t2.b1.r1.l2")
        #expect(kb.lexicon.conceptDimensions.count == 22)
        #expect(kb.lexicon.meaningWords["cool"]?["cool"] == 1)
    }

    @Test func everyTypeIsWellFormed() {
        for card in kb.types {
            #expect(card.code.count == 2, "\(card.id) code must be two letters")
            #expect(!card.description.isEmpty)
            for related in card.related { #expect(kb.typeCard(id: related) != nil, "\(card.id) relates to unknown \(related)") }
        }
    }

    @Test func unknownTypesMapToOther() {
        #expect(kb.typeCard(for: "ac").label == "Air Conditioner")
        #expect(kb.typeCard(for: "toaster").id == "other")
    }

    @Test func localizedLabelsArePresent() {
        #expect(kb.typeCard(for: "ac").localized["bn"] == ["এসি"])
        #expect(kb.typeCard(for: "ac").localized["de"] == ["klimaanlage"])
        #expect(kb.rooms.first { $0.id == "bedroom" }?.localized["bn"]?.contains("বেডরুম") == true)
    }

    @Test func pipelineUsesLexiconAbbreviations() {
        let pipeline = kb.makePipeline()
        #expect(pipeline.terms("A/C in Bob's room") == ["ac", "in", "bob", "room"])
    }
}

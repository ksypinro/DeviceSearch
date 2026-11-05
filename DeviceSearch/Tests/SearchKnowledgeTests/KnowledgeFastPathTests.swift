import Testing
@testable import SearchText
import SearchKnowledge

/// Every ASCII phrase in the knowledge base normalizes the same on the fast and general paths.
@Test func everyKnowledgeBasePhraseAgreesOnBothNormalizerPaths() throws {
    let knowledge = try KnowledgeBase.bundled()
    let normalizer = TextNormalizer()
    var phrases: [String] = []
    for card in knowledge.types { phrases += card.allNames }
    for brand in knowledge.brands { phrases += [brand.name] + brand.aliases }
    for room in knowledge.rooms { phrases += room.allNames }
    for text in phrases where text.utf8.allSatisfy({ $0 < 0x80 }) {
        #expect(normalizer.normalize(text) == normalizer.normalizeGeneral(text), "\(text)")
        #expect(normalizer.normalize(text, splitCamelCase: false) == normalizer.normalizeGeneral(text, splitCamelCase: false))
    }
}

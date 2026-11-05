import Testing
import SearchCore
import SearchText
import SearchKnowledge
@testable import SearchIndex

@Suite("Inverted index and vocabulary (direct)")
struct TermIndexTests {
    let documents = IndexFixtures.documents()

    func vocabulary(phoneticCache: [String: String] = [:]) -> Vocabulary {
        let phrases = PhraseDictionary(knowledge: IndexFixtures.knowledge, pipeline: IndexFixtures.pipeline, maxPhraseLength: 4)
        let meaning = Set(IndexFixtures.knowledge.lexicon.meaningWords.keys.map { IndexFixtures.pipeline.stemmer.stem($0) })
        return Vocabulary(documents: documents, entityTokens: phrases.entityTokens, meaningWords: meaning,
                          encoder: MetaphoneLite(), phoneticCache: phoneticCache)
    }

    @Test func postingsAndInverseDocumentFrequency() {
        let index = InvertedIndex(documents: documents)
        #expect(index.documents(containing: "bedroom") == [0])
        #expect(index.documents(containing: "§t:ac") == [0])
        #expect(index.documentFrequency("nothing") == 0)
        #expect(abs(index.idf("samsung") - 1.2039728) < 1e-6)   // N = 4, df = 1 → ln(1 + 3.5 / 1.5)
    }

    @Test func deviceWordsOutweighKnowledgeOnlyWords() {
        let vocabulary = vocabulary()
        #expect(vocabulary.frequency(of: "bedroom") == 1)
        #expect(vocabulary.frequency(of: "thermostat") == 0.5)
        #expect(vocabulary.frequency(of: "intruder") == 0.25)
        #expect(vocabulary.nameTerms.contains("ayaan"))
        #expect(!vocabulary.contains("2"))
    }

    @Test func completionsPreferFrequentShortTerms() {
        #expect(vocabulary().completions(for: "bed", limit: 3).first == "bedroom")
    }

    @Test func aPhoneticCacheChangesNothing() {
        let plain = vocabulary()
        let cache = Dictionary(uniqueKeysWithValues: plain.sortedTerms.map { ($0, MetaphoneLite().key(for: $0)) })
        #expect(vocabulary(phoneticCache: cache).phoneticTerms == plain.phoneticTerms)
    }
}

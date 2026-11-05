import Testing
import SearchCore
import SearchIndex
import SearchQuery
@testable import SearchRetrieval
import SearchTestSupport

/// Runs one retriever on the lab's 500-device home and returns device names, best first.
func names(_ retriever: any CandidateRetriever, _ text: String, mode: SearchMode = .submitted,
           snapshot: IndexSnapshot = TestIndex.home500) -> [String] {
    let query = QueryParser().parse(text, mode: mode, in: snapshot)
    return retriever.retrieve(query, in: snapshot, config: .default).map { snapshot.documents[$0.document].device.name }
}

@Suite("Lexical retrievers")
struct RetrieverTests {
    @Test func exactMatchesTheWholeName() {
        #expect(names(ExactRetriever(), "Bedroom AC") == ["Bedroom AC"])
        #expect(names(ExactRetriever(), "the bedroom ac") == ["Bedroom AC"])   // function words are ignored
        #expect(names(ExactRetriever(), "bedroom").isEmpty)
    }

    @Test func exactIgnoresLowConfidenceCorrections() {
        // "thermstt" → phonetic correction with confidence 0.6 (allowed); cost-1.5 edits have 0.55 (blocked).
        let query = QueryParser().parse("bedrom ac", mode: .submitted, in: TestIndex.home500)
        #expect(query.corrections.first?.confidence == 0.85)
        #expect(!ExactRetriever().retrieve(query, in: TestIndex.home500, config: .default).isEmpty)
    }

    @Test func prefixMatchesWhileTyping() {
        let hits = names(PrefixRetriever(), "bedr", mode: .typing)
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { $0.lowercased().contains("bedr") })
    }

    @Test func numbersNeverMatchAsPrefixes() {
        let hits = names(PrefixRetriever(), "tv 1", mode: .typing)
        #expect(!hits.contains("TV 12"))
        #expect(names(PrefixRetriever(), "tv 12").first == "TV 12")
    }

    @Test func keywordsIgnoreWordOrder() {
        #expect(names(KeywordRetriever(), "ac bedroom").first == names(KeywordRetriever(), "bedroom ac").first)
        #expect(names(KeywordRetriever(), "bedroom ac").first == "Bedroom AC")
    }

    @Test func keywordsMatchTypeSynonyms() {
        let hits = names(KeywordRetriever(), "aircon")
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { name in TestIndex.home500.documents.first { $0.device.name == name }!.typeID == "ac" })
    }

    @Test func trigramsFindGluedWords() {
        #expect(names(TrigramRetriever(), "livingroomtv").first == "Living Room TV")
        #expect(names(TrigramRetriever(), "tv").isEmpty)   // fewer than 3 characters
    }

    @Test func phoneticKeysFindSoundAlikes() {
        let snapshot = TestIndex.home500
        let hits = names(PhoneticRetriever(), "fillips hue")
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { name in
            let brand = snapshot.documents.first { $0.device.name == name }!.brandID
            return brand == "philips-hue" || brand == "philips"
        })
    }

    @Test func facetsApplyBitsetAlgebraAndRankByUsage() {
        let snapshot = TestIndex.home500
        let query = QueryParser().parse("lights except kitchen", mode: .submitted, in: snapshot)
        let hits = FacetRetriever().retrieve(query, in: snapshot, config: .default)
        #expect(!hits.isEmpty)
        for hit in hits {
            #expect(snapshot.documents[hit.document].typeID == "light")
            #expect(snapshot.documents[hit.document].roomID != "kitchen")
        }
        #expect(zip(hits, hits.dropFirst()).allSatisfy { $0.score >= $1.score })
    }

    @Test func everyRetrieverIsDeterministic() {
        for retriever in LexicalRetrievers.all {
            #expect(names(retriever, "kitchen light") == names(retriever, "kitchen light"))
        }
    }
}

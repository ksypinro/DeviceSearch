import SearchCore
import SearchIndex
import SearchText

/// Character trigrams (design doc §6) of the typed words without spaces against device names without spaces.
/// Catches glued words, partial names and typos the token step missed. Keeps Dice ≥ 0.30.
public struct TrigramRetriever: CandidateRetriever {
    public let id = RetrieverID.trigram

    public init() {}

    public func retrieve(_ query: ParsedQuery, in snapshot: IndexSnapshot, config: SearchConfig) -> [RetrievalHit] {
        guard query.typedKey.count >= 3 else { return [] }
        let grams = Trigrams.of(query.typedKey)
        var shared: [Int: Int] = [:]
        for gram in grams {
            for ordinal in snapshot.fuzzy.documents(withTrigram: gram) { shared[ordinal, default: 0] += 1 }
        }
        var hits: [RetrievalHit] = []
        for (ordinal, count) in shared {
            let dice = Trigrams.dice(shared: count, grams.count, snapshot.documents[ordinal].trigrams.count)
            if dice >= config.trigramMinDice { hits.append(RetrievalHit(document: ordinal, score: dice)) }
        }
        return hits.ranked(limit: config.trigramLimit)
    }
}

/// Phonetic keys (design doc §6) of the words that were misspelled (corrected or unknown, 3+ letters, not numbers),
/// encoded both as typed and stemmed.
/// Score = share of those words whose key matches a name or brand word. Ties: higher prior first.
public struct PhoneticRetriever: CandidateRetriever {
    public let id = RetrieverID.phonetic

    public init() {}

    public func retrieve(_ query: ParsedQuery, in snapshot: IndexSnapshot, config: SearchConfig) -> [RetrievalHit] {
        let words = query.wordTerms.filter { ($0.isCorrected || $0.isUnknown) && !$0.isNumber && $0.raw.count >= 3 }
        guard !words.isEmpty else { return [] }
        var scores: [Int: Double] = [:]
        let share = 1 / Double(words.count)
        for word in words {
            // Encode the word as typed and stemmed: "fillips" stems to "fillip" but must still meet "philips".
            let keys = Set([snapshot.encoder.key(for: word.raw),
                            snapshot.encoder.key(for: snapshot.pipeline.stemmer.stem(word.raw))]).filter { $0.count >= 2 }
            var matched = Set<Int>()
            for key in keys { matched.formUnion(snapshot.fuzzy.documents(withPhoneticKey: key)) }
            for ordinal in matched { scores[ordinal, default: 0] += share }
        }
        return scores.map { RetrievalHit(document: $0.key, score: $0.value) }
            .ranked(limit: config.phoneticLimit) { snapshot.documents[$0].prior }
    }
}

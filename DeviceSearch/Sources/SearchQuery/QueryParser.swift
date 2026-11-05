import SearchCore
import SearchIndex
import SearchKnowledge
import SearchText

/// Stages S1 and S2: raw text → `ParsedQuery` (design doc §5). Pure and deterministic; well under a millisecond.
public struct QueryParser: Sendable {
    public let config: SearchConfig

    public init(config: SearchConfig = .default) {
        self.config = config
    }

    public func parse(_ raw: String, mode: SearchMode, options: SearchOptions = .standard,
                      in snapshot: IndexSnapshot) -> ParsedQuery {
        var query = ParsedQuery(raw: raw, mode: mode)
        let lexed = QueryLexer().lex(raw, pipeline: snapshot.pipeline, lexicon: snapshot.knowledge.lexicon)
        query.normalized = lexed.normalized
        query.action = lexed.action
        query.tokens = lexed.tokens

        let corrected = TypoCorrector(config: config).classify(lexed.tokens, mode: mode, options: options,
                                                               snapshot: snapshot)
        query.terms = corrected.terms
        query.corrections = corrected.corrections
        query.completions = corrected.completions
        query.lastPrefix = corrected.lastPrefix

        let matched = EntityMatcher().match(corrected.terms, phrases: snapshot.phrases, stemmer: snapshot.pipeline.stemmer,
                                            meaningWords: snapshot.meaningWords)
        query.entities = matched.entities
        query.excluded = matched.excluded
        query.network = matched.network
        query.power = matched.power
        query.flags = matched.flags
        query.contentTerms = matched.contentTerms
        query.wordTerms = matched.wordTerms

        // Name terms: de-duplicated by term, keeping the highest confidence, in first-seen order.
        var nameTerms: [QueryTerm] = []
        var position: [String: Int] = [:]
        for term in matched.wordTerms where !term.isFunctionWord {
            if let existing = position[term.term] {
                if term.confidence > nameTerms[existing].confidence { nameTerms[existing] = term }
            } else {
                position[term.term] = nameTerms.count
                nameTerms.append(term)
            }
        }
        query.nameTerms = nameTerms
        query.highlightTerms = Set(nameTerms.map(\.term))

        let phrases = snapshot.phrases
        let stemmer = snapshot.pipeline.stemmer
        let typed = lexed.tokens.filter { !phrases.isFunctionToken($0) && !phrases.isFunctionToken(stemmer.stem($0)) }
        query.typedKey = typed.joined()
        query.cleanKey = typed.joined(separator: " ")
        query.sequenceAll = corrected.terms.map(\.term).joined(separator: " ")
        query.sequenceContent = corrected.terms.filter { !$0.isFunctionWord }.map(\.term).joined(separator: " ")
        query.correctedText = ([lexed.action].compactMap { $0 } + corrected.terms.map { $0.isCorrected ? $0.term : $0.raw })
            .joined(separator: " ")

        let classifier = IntentClassifier()
        let intent = classifier.classify(query, matched: matched, snapshot: snapshot)
        query.intent = intent.intent
        query.intentReason = intent.reason
        query.meaningTermCount = intent.meaningTerms
        query.hard = classifier.hardFilters(intent: intent.intent, matched: matched,
                                            minConfidence: config.minConfidenceForHardFilter)
        return query
    }

    /// A descriptive query with its meaning words marked `describesNeed`, for the hybrid phase once the meaning
    /// layer has answered: matched as names, "door" in "who is at the door" ranks the Front Door lock above the
    /// doorbell, while the meaning layer matches the words itself (device vectors include names). Words that
    /// also belong to an entity stay names. Nil when the query is not descriptive or has no such words.
    public func describingNeeds(_ query: ParsedQuery, in snapshot: IndexSnapshot) -> ParsedQuery? {
        guard query.intent == .descriptive else { return nil }
        var entityUses: [String: Int] = [:]
        for term in query.wordTerms { entityUses[term.term, default: 0] += 1 }
        for term in query.contentTerms { entityUses[term.term, default: 0] -= 1 }
        let needWords = Set(query.contentTerms.map(\.term).filter {
            snapshot.meaningWords.contains($0) && (entityUses[$0] ?? 0) <= 0
        })
        guard !needWords.isEmpty else { return nil }
        var marked = query
        for index in marked.nameTerms.indices where needWords.contains(marked.nameTerms[index].term) {
            marked.nameTerms[index].describesNeed = true
        }
        marked.highlightTerms.subtract(needWords)
        // "who's at the front door" must not pin the lock named "Front Door" as an exact match.
        marked.sequenceContent = query.terms.filter { !$0.isFunctionWord && !needWords.contains($0.term) }
            .map(\.term).joined(separator: " ")
        let phrases = snapshot.phrases
        let stemmer = snapshot.pipeline.stemmer
        marked.typedKey = query.tokens.filter {
            let stem = stemmer.stem($0)
            return !phrases.isFunctionToken($0) && !phrases.isFunctionToken(stem) && !needWords.contains(stem)
        }.joined()
        return marked
    }
}

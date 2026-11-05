import SearchCore
import SearchIndex
import SearchKnowledge
import SearchText

/// Classifies each token and corrects typos against the snapshot's vocabulary (design doc §5).
///
/// Order for one token:
/// 1. digits → exact number (never corrected)
/// 2. function word → kept
/// 3. known vocabulary term → kept
/// 4. dictionary-validated suffix stripping ("বেডরুমের" → "বেডরুম")
/// 5. glued words, 6+ characters ("livingroom" → "living room")
/// 6. last token while typing → prefix completion (on submit this step runs after 7 and 8)
/// 7. weighted edit distance within the length budget
/// 8. phonetic key
/// 9. unknown
public struct TypoCorrector: Sendable {
    public struct Output: Sendable {
        public var terms: [QueryTerm] = []
        public var corrections: [Correction] = []
        public var completions: [String] = []
        public var lastPrefix: String?
    }

    public let config: SearchConfig

    public init(config: SearchConfig = .default) {
        self.config = config
    }

    public func classify(_ tokens: [String], mode: SearchMode, options: SearchOptions,
                         snapshot: IndexSnapshot) -> Output {
        var output = Output()
        let vocabulary = snapshot.vocabulary
        let phrases = snapshot.phrases
        let stemmer = snapshot.pipeline.stemmer
        // Suffixes go through the same normalizer as queries: NFKD splits Bangla "ো" into "ে" + "া".
        let stripper = SuffixStripper(suffixes: snapshot.knowledge.lexicon.suffixes.map {
            snapshot.pipeline.normalizer.normalize($0)
        })

        for (index, token) in tokens.enumerated() {
            let stem = stemmer.stem(token)
            let isLast = index == tokens.count - 1

            if token.allSatisfy(\.isNumber) {
                output.terms.append(QueryTerm(raw: token, isNumber: true))
                continue
            }
            if phrases.isFunctionToken(token) || phrases.isFunctionToken(stem) {
                output.terms.append(QueryTerm(raw: token, term: stem, isFunctionWord: true))
                continue
            }
            if vocabulary.contains(stem) {
                output.terms.append(QueryTerm(raw: token, term: stem))
                continue
            }
            if options.allowCorrections,
               let stripped = (stripper.candidates(for: token) + stripper.candidates(for: stem)).first(where: vocabulary.contains) {
                output.terms.append(QueryTerm(raw: token, term: stripped, confidence: config.suffixConfidence))
                continue
            }
            if options.allowCorrections, stem.count >= config.compoundSplitMinLength,
               let parts = split(stem, vocabulary: vocabulary, phrases: phrases, stemmer: stemmer) {
                output.corrections.append(Correction(from: token, to: parts.joined(separator: " "), method: .split,
                                                     confidence: config.splitConfidence))
                for part in parts {
                    output.terms.append(QueryTerm(raw: part, confidence: config.splitConfidence, isCorrected: true))
                }
                continue
            }

            let tryPrefix: () -> Bool = {
                guard isLast, stem.count >= 2 else { return false }
                let completions = vocabulary.completions(for: stem, limit: config.maxCompletions)
                guard !completions.isEmpty else { return false }
                output.lastPrefix = stem
                output.completions = completions
                output.terms.append(QueryTerm(raw: token, term: stem, isPrefix: true))
                return true
            }

            if mode == .typing, tryPrefix() { continue }
            if options.allowCorrections {
                if let best = editCorrection(token: token, stem: stem, vocabulary: vocabulary,
                                             boost: options.typoBudgetBoost) {
                    let confidence = TypingDistance.confidence(forCost: best.cost, weight: config.correctionCostWeight)
                    output.corrections.append(Correction(from: token, to: best.term, method: .edit, cost: best.cost,
                                                         confidence: confidence))
                    output.terms.append(QueryTerm(raw: token, term: best.term, confidence: confidence, isCorrected: true))
                    continue
                }
                if let term = phoneticCorrection(token: token, stem: stem, snapshot: snapshot) {
                    output.corrections.append(Correction(from: token, to: term, method: .phonetic,
                                                         confidence: config.phoneticConfidence))
                    output.terms.append(QueryTerm(raw: token, term: term, confidence: config.phoneticConfidence,
                                                  isCorrected: true))
                    continue
                }
            }
            if mode == .submitted, tryPrefix() { continue }
            output.terms.append(QueryTerm(raw: token, term: stem, isUnknown: true))
        }
        return output
    }

    /// Two known, non-function halves; prefers the split whose shorter half is longest.
    func split(_ stem: String, vocabulary: Vocabulary, phrases: PhraseDictionary, stemmer: Stemmer) -> [String]? {
        let characters = Array(stem)
        guard characters.count >= 6 else { return nil }
        var best: (parts: [String], score: Int)?
        for cut in 3...(characters.count - 3) {
            let left = stemmer.stem(String(characters[..<cut]))
            let right = stemmer.stem(String(characters[cut...]))
            guard vocabulary.contains(left), vocabulary.contains(right),
                  !phrases.isFunctionToken(left), !phrases.isFunctionToken(right) else { continue }
            let score = min(left.count, right.count)
            if best == nil || score > best!.score { best = ([left, right], score) }
        }
        return best?.parts
    }

    /// Cheapest vocabulary term within the budget for the stemmed and the typed form.
    /// Ties: higher document frequency, then closer length, then alphabetical.
    func editCorrection(token: String, stem: String, vocabulary: Vocabulary, boost: Double) -> (term: String, cost: Double)? {
        var best: (term: String, cost: Double, frequency: Double, lengthGap: Int)?
        for form in Array(Set([stem, token])).sorted() {
            let limit = config.typoBudgets.maxCost(forLength: form.count) + boost
            let typed = Array(form)
            for length in max(1, typed.count - 2)...(typed.count + 2) {
                for term in vocabulary.termsByLength[length] ?? [] {
                    let cost = TypingDistance.distance(typed, Array(term), limit: limit)
                    guard cost <= limit else { continue }
                    let candidate = (term, cost, vocabulary.frequency(of: term), abs(term.count - typed.count))
                    if let current = best {
                        let better = cost < current.cost
                            || (cost == current.cost && candidate.2 > current.frequency)
                            || (cost == current.cost && candidate.2 == current.frequency && candidate.3 < current.lengthGap)
                            || (cost == current.cost && candidate.2 == current.frequency && candidate.3 == current.lengthGap
                                && term < current.term)
                        if better { best = candidate }
                    } else {
                        best = candidate
                    }
                }
            }
        }
        return best.map { ($0.term, $0.cost) }
    }

    /// The most frequent vocabulary term sharing a phonetic key, within three characters of the typed length.
    func phoneticCorrection(token: String, stem: String, snapshot: IndexSnapshot) -> String? {
        let keys = Set([snapshot.encoder.key(for: stem), snapshot.encoder.key(for: token)]).filter { $0.count >= 2 }
        let candidates = Set(keys.flatMap { snapshot.vocabulary.phoneticTerms[$0] ?? [] })
            .filter { abs($0.count - token.count) <= 3 }
        return candidates.sorted { a, b in
            let fa = snapshot.vocabulary.frequency(of: a), fb = snapshot.vocabulary.frequency(of: b)
            if fa != fb { return fa > fb }
            if a.count != b.count { return a.count < b.count }
            return a < b
        }.first
    }
}

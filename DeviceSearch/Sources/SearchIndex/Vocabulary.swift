import SearchKnowledge
import SearchText

/// Every term a typo can be corrected to, with its document frequency (design doc §6).
/// Terms from device fields count their documents; knowledge-base-only terms count 0.5 and
/// meaning-lexicon-only terms 0.25, so real device words win ties.
public struct Vocabulary: Sendable {
    public let frequency: [String: Double]
    /// Terms grouped by character count, for length-bucketed typo search.
    public let termsByLength: [Int: [String]]
    /// Sorted terms, for prefix completion.
    public let sortedTerms: [String]
    /// Phonetic key → terms.
    public let phoneticTerms: [String: [String]]
    /// Terms that occur in device names.
    public let nameTerms: Set<String>

    /// - Parameter phoneticCache: precomputed phonetic keys (the index builder caches the knowledge-base terms).
    public init(documents: [SearchDocument], entityTokens: Set<String>, meaningWords: Set<String>,
                encoder: any PhoneticEncoding, phoneticCache: [String: String] = [:]) {
        var frequency: [String: Double] = [:]
        var nameTerms = Set<String>()
        for document in documents {
            var seen = Set<String>()
            for field in SearchField.allCases {
                for token in document.fieldTokens[field] ?? [] where Self.isWord(token) && seen.insert(token).inserted {
                    frequency[token, default: 0] += 1
                }
            }
            nameTerms.formUnion(document.nameTokens)
        }
        for token in entityTokens where Self.isWord(token) && frequency[token] == nil { frequency[token] = 0.5 }
        for token in meaningWords where Self.isWord(token) && frequency[token] == nil { frequency[token] = 0.25 }

        var byLength: [Int: [String]] = [:]
        var phonetic: [String: [String]] = [:]
        var sorted: [String] = []
        for term in frequency.keys where !term.allSatisfy(\.isNumber) {
            byLength[term.count, default: []].append(term)
            sorted.append(term)
            let key = phoneticCache[term] ?? encoder.key(for: term)
            if key.count >= 2 { phonetic[key, default: []].append(term) }
        }
        for key in byLength.keys { byLength[key]!.sort() }
        for key in phonetic.keys { phonetic[key]!.sort() }
        sorted.sort()
        self.frequency = frequency
        self.termsByLength = byLength
        self.sortedTerms = sorted
        self.phoneticTerms = phonetic
        self.nameTerms = nameTerms
    }

    /// At least two characters and not an internal entity token.
    static func isWord(_ token: String) -> Bool { token.count >= 2 && !token.hasPrefix("§") }

    public func contains(_ term: String) -> Bool { frequency[term] != nil }

    public func frequency(of term: String) -> Double { frequency[term] ?? 0 }

    /// Terms starting with `prefix` (excluding `prefix` itself), most frequent first, then shortest, then alphabetical.
    public func completions(for prefix: String, limit: Int) -> [String] {
        guard !prefix.isEmpty else { return [] }
        var low = 0
        var high = sortedTerms.count
        while low < high {
            let mid = (low + high) / 2
            if sortedTerms[mid] < prefix { low = mid + 1 } else { high = mid }
        }
        var matches: [String] = []
        var index = low
        while index < sortedTerms.count, sortedTerms[index].hasPrefix(prefix) {
            if sortedTerms[index] != prefix { matches.append(sortedTerms[index]) }
            index += 1
        }
        matches.sort { a, b in
            let fa = frequency(of: a), fb = frequency(of: b)
            if fa != fb { return fa > fb }
            if a.count != b.count { return a.count < b.count }
            return a < b
        }
        return Array(matches.prefix(limit))
    }
}

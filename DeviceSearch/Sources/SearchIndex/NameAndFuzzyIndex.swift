import SearchText

/// Exact-name lookup (design doc §6). Keys are stemmed tokens joined by spaces, for both camel-split and
/// unsplit forms of each name, plus learned nicknames.
public struct NameIndex: Sendable {
    public let exact: [String: [Int]]

    public init(documents: [SearchDocument], pipeline: TextPipeline, aliases: [Int: [String]]) {
        var exact: [String: [Int]] = [:]
        func add(_ key: String, _ ordinal: Int) {
            guard !key.isEmpty else { return }
            if !(exact[key]?.contains(ordinal) ?? false) { exact[key, default: []].append(ordinal) }
        }
        for document in documents {
            if document.nameKeys.isEmpty {
                add(pipeline.key(document.device.name), document.ordinal)
                add(pipeline.key(document.device.name, splitCamelCase: false), document.ordinal)
            } else {
                for key in document.nameKeys { add(key, document.ordinal) }
            }
            for alias in aliases[document.ordinal] ?? [] { add(pipeline.key(alias), document.ordinal) }
        }
        self.exact = exact
    }

    public func documents(named key: String) -> [Int] { exact[key] ?? [] }
}

/// Character trigrams of compact names and phonetic keys of name and brand words (design doc §6).
public struct FuzzyIndex: Sendable {
    public let trigramPostings: [String: [Int]]
    public let phoneticPostings: [String: [Int]]

    /// - Parameter phoneticCache: precomputed keys (knowledge-base terms); other words are encoded once per build.
    public init(documents: [SearchDocument], encoder: any PhoneticEncoding, phoneticCache: [String: String] = [:]) {
        var trigrams: [String: [Int]] = [:]
        var phonetic: [String: [Int]] = [:]
        var encoded = phoneticCache   // words repeat across devices ("light", "kitchen")
        for document in documents {
            for gram in document.trigrams { trigrams[gram, default: []].append(document.ordinal) }
            let brandWords = (document.fieldTokens[.brand] ?? []).filter { !$0.hasPrefix("§") }
            var keys = Set<String>()
            for word in document.nameTokens + brandWords where word.count >= 3 && !word.contains(where: \.isNumber) {
                let key = encoded[word] ?? encoder.key(for: word)
                encoded[word] = key
                if key.count >= 2 { keys.insert(key) }
            }
            for key in keys { phonetic[key, default: []].append(document.ordinal) }
        }
        self.trigramPostings = trigrams
        self.phoneticPostings = phonetic
    }

    public func documents(withTrigram gram: String) -> [Int] { trigramPostings[gram] ?? [] }

    public func documents(withPhoneticKey key: String) -> [Int] { phoneticPostings[key] ?? [] }
}

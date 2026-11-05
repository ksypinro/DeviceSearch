import Foundation

/// Term → documents over every BM25F field, plus the field statistics BM25F needs.
public struct InvertedIndex: Sendable {
    /// Ascending document ordinals per term (internal entity tokens included).
    public let postings: [String: [Int]]
    public let averageFieldLength: [SearchField: Double]
    public let documentCount: Int

    public init(documents: [SearchDocument]) {
        var postings: [String: [Int]] = [:]
        var totals: [SearchField: Int] = [:]
        for document in documents {
            var seen = Set<String>()
            for field in SearchField.allCases {
                let tokens = document.fieldTokens[field] ?? []
                totals[field, default: 0] += tokens.count
                for token in tokens where seen.insert(token).inserted {
                    postings[token, default: []].append(document.ordinal)
                }
            }
        }
        self.postings = postings
        self.documentCount = documents.count
        var averages: [SearchField: Double] = [:]
        for field in SearchField.allCases {
            averages[field] = documents.isEmpty ? 0 : Double(totals[field] ?? 0) / Double(documents.count)
        }
        self.averageFieldLength = averages
    }

    public func documents(containing term: String) -> [Int] { postings[term] ?? [] }

    public func documentFrequency(_ term: String) -> Int { postings[term]?.count ?? 0 }

    /// BM25 inverse document frequency: ln(1 + (N − df + 0.5) / (df + 0.5)).
    public func idf(_ term: String) -> Double {
        let df = Double(documentFrequency(term))
        let n = Double(documentCount)
        return log(1 + (n - df + 0.5) / (df + 0.5))
    }
}

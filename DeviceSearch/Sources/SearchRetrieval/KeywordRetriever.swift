import SearchCore
import SearchIndex

/// Field-weighted BM25 (BM25F, design doc §6) over name, alias, type, brand and room.
///
///     tf~(t,d) = Σ_f  w_f · tf(t,d,f) / (1 − b_f + b_f · len(d,f) / avglen_f)
///     score(d) = Σ_t  q_t · idf(t) · tf~(t,d) / (k1 + tf~(t,d))
///
/// Query weights q_t: typed words 1, corrected words their confidence, completions of the last word 0.7,
/// and each parsed entity's internal token ("§t:ac") at the entity's confidence.
public struct KeywordRetriever: CandidateRetriever {
    public let id = RetrieverID.keywords

    public init() {}

    public func retrieve(_ query: ParsedQuery, in snapshot: IndexSnapshot, config: SearchConfig) -> [RetrievalHit] {
        var queryWeights: [String: Double] = [:]
        var order: [String] = []
        func add(_ term: String, _ weight: Double) {
            guard !term.isEmpty else { return }
            if queryWeights[term] == nil { order.append(term) }
            if weight > (queryWeights[term] ?? 0) { queryWeights[term] = weight }
        }
        for term in query.nameTerms where !term.describesNeed { add(term.term, term.confidence) }
        for completion in query.completions { add(completion, config.completionWeight) }
        for entity in query.entities { if let token = entity.specialToken { add(token, entity.confidence) } }

        let inverted = snapshot.inverted
        var scores: [Int: Double] = [:]
        for term in order {
            let postings = inverted.documents(containing: term)
            guard !postings.isEmpty else { continue }
            let idf = inverted.idf(term)
            let weight = queryWeights[term] ?? 0
            for ordinal in postings {
                let document = snapshot.documents[ordinal]
                var tf = 0.0
                for field in SearchField.allCases {
                    let count = document.frequency(of: term, in: field)
                    guard count > 0 else { continue }
                    let parameter = Self.parameter(field, config.fields)
                    let average = inverted.averageFieldLength[field] ?? 0
                    let lengthRatio = average > 0 ? Double(document.length(of: field)) / average : 1
                    tf += parameter.weight * Double(count)
                        / (1 - parameter.lengthNormalization + parameter.lengthNormalization * lengthRatio)
                }
                if tf > 0 { scores[ordinal, default: 0] += weight * idf * tf / (config.bm25K1 + tf) }
            }
        }
        return scores.map { RetrievalHit(document: $0.key, score: $0.value) }.ranked(limit: config.keywordLimit)
    }

    static func parameter(_ field: SearchField, _ fields: FieldParameters) -> FieldParameter {
        switch field {
        case .name: return fields.name
        case .alias: return fields.alias
        case .type: return fields.type
        case .brand: return fields.brand
        case .room: return fields.room
        }
    }
}

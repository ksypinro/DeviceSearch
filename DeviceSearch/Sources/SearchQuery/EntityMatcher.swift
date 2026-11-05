import SearchCore
import SearchKnowledge
import SearchText

/// Walks the classified terms left to right and takes the longest phrase found in the phrase dictionary
/// (design doc §5). Produces entities, exclusions, status filters, flags and the remaining content words.
///
/// - Negation ("except", "not", "without", "other than") applies to the next entity only.
/// - A room preposition ("in", "at") makes the next room an explicit filter.
/// - Quantifiers ("all") and plural types ("lights") mark a set query.
/// - A one-word power state before a meaning word is not a state: "on fire", "an eye on the baby".
public struct EntityMatcher: Sendable {
    public struct Output: Sendable {
        public var entities: [QueryEntity] = []
        public var excluded: [QueryEntity] = []
        public var network: StatusCondition?
        public var power: StatusCondition?
        public var flags = QueryFlags()
        /// Terms outside any phrase and not function words.
        public var contentTerms: [QueryTerm] = []
        /// Content terms plus the words of non-negated entities, in order (function words included; callers filter).
        public var wordTerms: [QueryTerm] = []
    }

    public init() {}

    public func match(_ terms: [QueryTerm], phrases: PhraseDictionary, stemmer: Stemmer,
                      meaningWords: Set<String> = []) -> Output {
        var output = Output()
        var pendingNegation = false
        var pendingPreposition = false
        let keys = terms.map(\.term)
        var index = 0

        while index < terms.count {
            guard let match = phrases.longestMatch(in: keys, from: index) else {
                let term = terms[index]
                if !term.isFunctionWord {
                    output.contentTerms.append(term)
                    output.wordTerms.append(term)
                }
                index += 1
                continue
            }
            let span = Array(terms[index..<(index + match.length)])
            let words = span.map(\.raw).joined(separator: " ")
            let confidence = span.map(\.confidence).min() ?? 1
            let negated = pendingNegation
            var consumed = false

            for entry in match.entries {
                switch entry.kind {
                case .negation: pendingNegation = true
                case .quantifier: output.flags.quantifier = true
                case .preposition: pendingPreposition = true
                case .generic: output.flags.setNoun = true
                case .need: output.flags.needWords += 1
                case .stop: break
                case .status:
                    if match.length == 1, StatusCondition(rawValue: entry.id)?.isPower == true,
                       let next = keys[(index + 1)...].first(where: { !phrases.isFunctionToken($0) }),
                       meaningWords.contains(next) { continue }
                    consumed = true
                    let entity = QueryEntity(kind: .status, id: entry.id, label: entry.label, words: words,
                                             confidence: confidence)
                    if negated {
                        output.excluded.append(entity)
                    } else if let condition = StatusCondition(rawValue: entry.id) {
                        if condition.isPower { output.power = condition } else { output.network = condition }
                    }
                case .type, .brand, .room:
                    consumed = true
                    let kind: EntityKind = entry.kind == .type ? .type : (entry.kind == .brand ? .brand : .room)
                    var entity = QueryEntity(kind: kind, id: entry.id, label: entry.label, words: words,
                                             confidence: confidence, roomTokens: entry.roomTokens)
                    if negated {
                        output.excluded.append(entity)
                    } else {
                        if kind == .room && pendingPreposition {
                            entity.isHard = true
                            output.flags.roomPreposition = true
                        }
                        if kind == .type && span.contains(where: { $0.raw.hasSuffix("s") && stemmer.stem($0.raw) != $0.raw }) {
                            output.flags.plural = true
                        }
                        output.entities.append(entity)
                    }
                }
            }
            if consumed {
                if !negated { output.wordTerms.append(contentsOf: span) }
                pendingNegation = false
                pendingPreposition = false
            }
            index += match.length
        }
        return output
    }
}

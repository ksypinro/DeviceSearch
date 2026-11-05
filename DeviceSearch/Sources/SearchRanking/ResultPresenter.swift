import SearchCore
import SearchIndex
import SearchText

/// Extra evidence from plug-ins, used for reason chips.
public struct PresentationContext: Sendable {
    /// Human label of the query's meaning, for example "cooling" (milestone 2).
    public var meaningLabel: String?
    /// Why the personal retriever returned an ordinal: `.usualPick` or `.favorite` (milestone 4).
    public var personalReasons: [Int: ReasonKind]

    public init(meaningLabel: String? = nil, personalReasons: [Int: ReasonKind] = [:]) {
        self.meaningLabel = meaningLabel
        self.personalReasons = personalReasons
    }
}

/// Stage S8 (design doc §9): sections, display scores, highlights and deterministic reason chips.
/// Reasons come only from evidence, never from model text (P04).
public struct ResultPresenter: Sendable {
    public let config: SearchConfig

    public init(config: SearchConfig = .default) {
        self.config = config
    }

    /// Rows for the instant, hybrid and fallback phases.
    /// Set queries list every member; other queries split into Best matches (exact or ≥ 55% of the top score,
    /// at most 8) and Related (≥ 20%, at most 10).
    public func fusedResults(query: ParsedQuery, fusion: FusionResult, snapshot: IndexSnapshot,
                             context: PresentationContext = PresentationContext()) -> [SearchResult] {
        let candidates = fusion.candidates
        guard let maxScore = candidates.map(\.score).max(), maxScore > 0 else {
            return candidates.map { makeResult($0, section: query.intent.isSet ? .set : .related, score: 0,
                                                query: query, snapshot: snapshot, context: context) }
        }
        if query.intent.isSet {
            return candidates.map {
                makeResult($0, section: $0.isExact ? .best : .set, score: $0.score / maxScore,
                           query: query, snapshot: snapshot, context: context)
            }
        }
        var results: [SearchResult] = []
        var best = 0
        var related = 0
        for candidate in candidates {
            let normalized = candidate.score / maxScore
            if candidate.isExact || (normalized >= config.bestThreshold && best < config.maxBestRows) {
                results.append(makeResult(candidate, section: .best, score: normalized, query: query,
                                          snapshot: snapshot, context: context))
                best += 1
            } else if normalized >= config.relatedThreshold && related < config.maxRelatedRows {
                results.append(makeResult(candidate, section: .related, score: normalized, query: query,
                                          snapshot: snapshot, context: context))
                related += 1
            }
        }
        return results
    }

    /// Favorites and frequently used devices, for an empty query (P09) and the end of the zero-result ladder.
    public func emptyState(snapshot: IndexSnapshot) -> [SearchResult] {
        let documents = snapshot.documents.sorted { a, b in
            a.prior != b.prior ? a.prior > b.prior : a.ordinal < b.ordinal
        }.prefix(config.emptyStateCount)
        return documents.map { document in
            let reason = document.device.usage?.isFavorite == true
                ? ReasonChip(kind: .favorite, text: "Favorite")
                : ReasonChip(kind: .oftenUsed, text: "Often used")
            return SearchResult(device: document.device, typeLabel: document.typeCard.label,
                                typeCode: document.typeCard.code, section: .recent, score: document.prior,
                                reasons: [reason], document: document.ordinal)
        }
    }

    public func makeResult(_ candidate: FusedCandidate, section: ResultSection, score: Double, query: ParsedQuery,
                           snapshot: IndexSnapshot, context: PresentationContext, rankChange: Int = 0) -> SearchResult {
        let document = snapshot.documents[candidate.document]
        return SearchResult(
            device: document.device, typeLabel: document.typeCard.label, typeCode: document.typeCard.code,
            section: section, score: min(1, max(0, score)),
            highlights: Self.highlights(name: document.device.name, query: query, pipeline: snapshot.pipeline),
            reasons: Self.reasons(candidate, document: document, query: query, context: context),
            rankChange: rankChange, evidence: candidate.evidence, document: candidate.document)
    }

    /// Reason chips, at most four, in a fixed order.
    public static func reasons(_ candidate: FusedCandidate, document: SearchDocument, query: ParsedQuery,
                               context: PresentationContext) -> [ReasonChip] {
        var chips: [ReasonChip] = []
        func add(_ kind: ReasonKind, _ text: String) {
            if !chips.contains(where: { $0.text == text }) { chips.append(ReasonChip(kind: kind, text: text)) }
        }
        if candidate.isExact { add(.exactName, "Exact name") }
        for correction in query.corrections
        where correction.to.split(separator: " ").contains(where: { document.allTokens.contains(String($0)) }) {
            switch correction.method {
            case .phonetic: add(.soundsLike, "Sounds like: \(correction.from) → \(correction.to)")
            case .split: add(.split, "Split: \(correction.from) → \(correction.to)")
            case .edit, .suffix: add(.typo, "Typo: \(correction.from) → \(correction.to)")
            }
        }
        for entity in query.entities {
            let strength = RankFuser.match(entity, document)
            guard strength >= 0.75 else { continue }
            switch entity.kind {
            case .type: add(.type, "Type: \(entity.label)")
            case .brand: add(.brand, "Brand: \(entity.label)")
            case .room: add(.room, "Room: \(strength < 1 ? (document.room?.name ?? entity.label) : entity.label)")
            case .status: break
            }
        }
        if let network = query.network, let status = document.device.status {
            if network == .offline && !status.isOnline { add(.status, "Offline") }
            if network == .online && status.isOnline { add(.status, "Online") }
        }
        if let power = query.power, let isOn = document.device.status?.isOn {
            if power == .on && isOn { add(.status, "On") }
            if power == .off && !isOn { add(.status, "Off") }
        }
        let evidence = candidate.evidence
        if evidence.contains(.prefix) && !candidate.isExact { add(.nameMatch, "Name match") }
        if let label = context.meaningLabel, evidence.contains(.semantic) || evidence.contains(.concept),
           query.intent == .descriptive || query.entities.isEmpty {
            add(.meaning, "Meaning: \(label)")
        }
        if evidence.contains(.trigram), query.intent == .navigational, candidate.coverage < 1, query.corrections.isEmpty,
           !candidate.isExact, !evidence.contains(.prefix) {
            add(.closeSpelling, "Close spelling")
        }
        if evidence.contains(.personal) {
            if context.personalReasons[candidate.document] == .usualPick {
                add(.usualPick, "Your usual pick")
            } else {
                add(.favorite, "Favorite")
            }
        }
        return Array(chips.prefix(4))
    }

    /// Character ranges of name words that match a query term, or start with the word being typed.
    public static func highlights(name: String, query: ParsedQuery, pipeline: TextPipeline) -> [HighlightRange] {
        guard !query.highlightTerms.isEmpty || query.lastPrefix != nil else { return [] }
        var ranges: [HighlightRange] = []
        let characters = Array(name)
        var start = 0
        while start < characters.count {
            if characters[start].isWhitespace { start += 1; continue }
            var end = start
            while end < characters.count && !characters[end].isWhitespace { end += 1 }
            let terms = pipeline.terms(String(characters[start..<end]))
            let hit = terms.contains { term in
                query.highlightTerms.contains(term) || (query.lastPrefix.map { term.hasPrefix($0) } ?? false)
            }
            if hit { ranges.append(HighlightRange(lowerBound: start, upperBound: end)) }
            start = end
        }
        return ranges
    }

    /// "31 devices" with the most common types and rooms (P03).
    public static func setSummary(for results: [SearchResult], limit: Int = 5) -> SetSummary {
        func chips(_ labels: [String]) -> [FacetChip] {
            Dictionary(grouping: labels, by: { $0 })
                .map { FacetChip(label: $0.key, count: $0.value.count) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
                .prefix(limit).map { $0 }
        }
        return SetSummary(count: results.count,
                          types: chips(results.map(\.typeLabel)),
                          rooms: chips(results.compactMap(\.device.room)))
    }

    /// The command and its targets (all result rows), when the query starts with an action verb.
    /// Set queries act on every row; an action on a need ("play music in the kitchen") acts on the best matches.
    public static func command(for query: ParsedQuery, results: [SearchResult]) -> DetectedCommand? {
        guard let action = query.action else { return nil }
        let targets = query.intent.isSet ? results : results.filter { $0.section == .best }
        guard !targets.isEmpty else { return nil }
        return DetectedCommand(verb: action, targets: targets.map(\.id))
    }
}

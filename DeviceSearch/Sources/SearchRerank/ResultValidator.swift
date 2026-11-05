import SearchCore

/// Stage S7 (design doc §9): the model's answer is a suggestion; these rules make the final list.
///
/// - V1 membership: numbers outside 1…K are dropped.
/// - V2 uniqueness: a number already placed is dropped.
/// - V3 hard filters: a candidate that fails the query's filters is dropped.
/// - V4 pinning: an exact name match goes first.
/// - V5 omission recovery: a candidate matching every query word is kept even if the model left it out.
/// - V6 blend and threshold: final = λ·model + (1−λ)·fused; rows below 0.15 are hidden. If nothing qualifies,
///   the top five fused candidates are shown.
public struct ResultValidator: Sendable {
    public enum Group: String, Sendable, Equatable {
        case best, related, recovered, dropped

        public var section: ResultSection {
            switch self {
            case .best: return .best
            case .related, .dropped: return .related
            case .recovered: return .other
            }
        }
    }

    public struct Row: Sendable, Equatable {
        /// 1-based number in the prompt (fused position).
        public var number: Int
        public var candidate: FusedCandidate
        /// Score implied by the model's placement.
        public var modelScore: Double
        /// Fused score normalized by the top candidate.
        public var fusedScore: Double
        public var finalScore: Double
        public var group: Group
    }

    /// A rule that fired, for diagnostics. Messages never contain device names or query text.
    public struct Note: Sendable, Equatable {
        public var rule: String
        public var message: String
    }

    public struct Validation: Sendable {
        /// Rows to show, in final order.
        public var rows: [Row]
        public var notes: [Note]
        public var lambda: Double
        /// Rules that corrected the model (V1–V5, or V6 when nothing qualified). Normal hiding is not counted.
        public var interventions: [String]
        /// Agreement between fused order and final order (−1…1); nil for fewer than two rows.
        public var kendallTau: Double?
    }

    public let config: SearchConfig

    public init(config: SearchConfig = .default) {
        self.config = config
    }

    public func validate(_ answer: RerankAnswer, candidates: [FusedCandidate], intent: QueryIntent) -> Validation {
        var notes: [Note] = []
        var interventions = Set<String>()
        func note(_ rule: String, _ message: String, counts: Bool = true) {
            notes.append(Note(rule: rule, message: message))
            if counts { interventions.insert(rule) }
        }

        var seen = Set<Int>()
        var best = admit(answer.best, label: "best", candidates: candidates, seen: &seen, note: note)
        var related = admit(answer.related, label: "related", candidates: candidates, seen: &seen, note: note)

        // V4: exact matches first (the earliest exact candidate ends on top).
        for (index, candidate) in candidates.enumerated().reversed() where candidate.isExact && candidate.passesHardFilters {
            let number = index + 1
            guard best.first != number else { continue }
            best = [number] + best.filter { $0 != number }
            related.removeAll { $0 == number }
            seen.insert(number)
            note("V4", "Pinned exact match #\(number) to the top")
        }

        // V5: keep candidates that match every query word.
        var recovered: [Int] = []
        for (index, candidate) in candidates.enumerated() where !seen.contains(index + 1) {
            guard candidate.coverage >= 0.99, candidate.passesHardFilters else { continue }
            recovered.append(index + 1)
            seen.insert(index + 1)
            note("V5", "Kept #\(index + 1): left out by the model, but every query word matches")
        }

        // V6: blend and threshold.
        let lambda = config.blendLambda(for: intent)
        let maxFused = max(candidates.map(\.score).max() ?? 0, 1e-6)
        var modelScores: [Int: Double] = [:]
        for (position, number) in best.enumerated() { modelScores[number] = 1 - config.bestPositionStep * Double(position) }
        for (position, number) in related.enumerated() {
            modelScores[number] = config.relatedBase - config.relatedPositionStep * Double(position)
        }
        for number in recovered { modelScores[number] = config.recoveredScore }

        let all: [Row] = candidates.enumerated().map { index, candidate in
            let number = index + 1
            let model = modelScores[number] ?? 0
            let fused = candidate.score / maxFused
            let group: Group = best.contains(number) ? .best
                : related.contains(number) ? .related
                : recovered.contains(number) ? .recovered : .dropped
            return Row(number: number, candidate: candidate, modelScore: model, fusedScore: fused,
                       finalScore: lambda * model + (1 - lambda) * fused, group: group)
        }
        var shown = all.filter { $0.group != .dropped && $0.finalScore >= config.displayThreshold }
        let hidden = all.count - shown.count
        if hidden > 0 { note("V6", "Hid \(hidden) candidate(s) the model left out or scored below the threshold", counts: false) }
        if shown.isEmpty {
            shown = all.filter { $0.candidate.passesHardFilters }.prefix(5).map { row in
                var row = row
                row.group = .related
                return row
            }
            note("V6", "Nothing qualified, so the top fused candidates are shown")
        }
        shown.sort(by: Self.finalOrder)
        return Validation(rows: shown, notes: notes, lambda: lambda, interventions: interventions.sorted(),
                          kendallTau: Self.kendallTau(shown.map(\.number)))
    }

    /// Partial rows while streaming: the validated `best` rows lock in at the top (V1–V4), and every other
    /// candidate follows in fused order. Nothing is hidden until the full answer arrives.
    public func lockedTop(_ bestNumbers: [Int], candidates: [FusedCandidate], intent: QueryIntent) -> [Row] {
        var seen = Set<Int>()
        var best = admit(bestNumbers, label: "best", candidates: candidates, seen: &seen) { _, _, _ in }
        for (index, candidate) in candidates.enumerated().reversed() where candidate.isExact && candidate.passesHardFilters {
            best = [index + 1] + best.filter { $0 != index + 1 }
        }
        let lambda = config.blendLambda(for: intent)
        let maxFused = max(candidates.map(\.score).max() ?? 0, 1e-6)
        var rows: [Row] = best.enumerated().map { position, number in
            let candidate = candidates[number - 1]
            let model = 1 - config.bestPositionStep * Double(position)
            let fused = candidate.score / maxFused
            return Row(number: number, candidate: candidate, modelScore: model, fusedScore: fused,
                       finalScore: lambda * model + (1 - lambda) * fused, group: .best)
        }
        for (index, candidate) in candidates.enumerated() where !best.contains(index + 1) && candidate.passesHardFilters {
            let fused = candidate.score / maxFused
            rows.append(Row(number: index + 1, candidate: candidate, modelScore: 0, fusedScore: fused,
                            finalScore: (1 - lambda) * fused, group: .related))
        }
        return rows
    }

    /// V1–V3 for one array.
    private func admit(_ numbers: [Int], label: String, candidates: [FusedCandidate], seen: inout Set<Int>,
                       note: (String, String, Bool) -> Void) -> [Int] {
        var kept: [Int] = []
        for number in numbers {
            guard (1...candidates.count).contains(number) else {
                note("V1", "Dropped #\(number) from \(label): not a candidate number", true)
                continue
            }
            guard !seen.contains(number) else {
                note("V2", "Dropped repeated #\(number) from \(label)", true)
                continue
            }
            guard candidates[number - 1].passesHardFilters else {
                note("V3", "Dropped #\(number): violates a filter", true)
                continue
            }
            seen.insert(number)
            kept.append(number)
        }
        return kept
    }

    /// Exact first, then best, related, recovered; then final score; then fused position (D17).
    static func finalOrder(_ a: Row, _ b: Row) -> Bool {
        if a.candidate.isExact != b.candidate.isExact { return a.candidate.isExact }
        let rank: [Group: Int] = [.best: 0, .related: 1, .recovered: 2, .dropped: 3]
        if rank[a.group]! != rank[b.group]! { return rank[a.group]! < rank[b.group]! }
        if a.finalScore != b.finalScore { return a.finalScore > b.finalScore }
        return a.number < b.number
    }

    /// Kendall's τ between the fused order (1, 2, 3…) and `order`.
    public static func kendallTau(_ order: [Int]) -> Double? {
        guard order.count >= 2 else { return nil }
        var concordant = 0
        var discordant = 0
        for i in 0..<order.count {
            for j in (i + 1)..<order.count {
                if order[i] < order[j] { concordant += 1 } else { discordant += 1 }
            }
        }
        return Double(concordant - discordant) / Double(concordant + discordant)
    }
}

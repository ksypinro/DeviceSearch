import SearchCore
import SearchIndex

/// Zero-result ladder, step 1 (design doc §9): when nothing passes every hard filter, drop the weakest filter
/// one at a time — status, then room, then brand, then type, then exclusions — until something matches.
/// The dropped filters are reported so the UI can say which one was relaxed.
public struct FilterRelaxation: Sendable {
    public let fuser: RankFuser

    public init(fuser: RankFuser) {
        self.fuser = fuser
    }

    public static let order: [RelaxedFilter] = [.status, .room, .brand, .type, .exclusions]

    public func relaxIfNeeded(_ query: ParsedQuery, lists: [RankedList], fusion: FusionResult,
                              snapshot: IndexSnapshot) -> (query: ParsedQuery, fusion: FusionResult) {
        guard query.hasHardFilters, fusion.candidates.isEmpty else { return (query, fusion) }
        var relaxedQuery = query
        var result = fusion
        var dropped: [RelaxedFilter] = []
        for step in Self.order {
            guard Self.drop(step, from: &relaxedQuery.hard) else { continue }
            dropped.append(step)
            result = fuser.fuse(lists, query: relaxedQuery, snapshot: snapshot)
            if !result.candidates.isEmpty { break }
        }
        result.relaxed = dropped
        return (relaxedQuery, result)
    }

    /// Removes one kind of filter. Returns false when that kind was not set.
    static func drop(_ step: RelaxedFilter, from hard: inout HardFilters) -> Bool {
        switch step {
        case .status:
            guard hard.network != nil || hard.power != nil else { return false }
            hard.network = nil
            hard.power = nil
        case .room:
            guard !hard.rooms.isEmpty else { return false }
            hard.rooms = []
        case .brand:
            guard !hard.brands.isEmpty else { return false }
            hard.brands = []
        case .type:
            guard !hard.types.isEmpty else { return false }
            hard.types = []
        case .exclusions:
            guard !hard.excluded.isEmpty else { return false }
            hard.excluded = []
        case .spelling, .meaningOnly, .rewrite:
            return false
        }
        return true
    }
}

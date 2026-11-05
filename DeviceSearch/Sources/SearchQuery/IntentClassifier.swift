import SearchCore
import SearchIndex

/// Intent rules (design doc §5), first match wins:
/// 1. starts with an action verb → command, unless it acts on a need and names no device
///    ("play music in the kitchen") → descriptive
/// 2. only entities, with a quantifier, plural, exclusion or status, or a single entity → categorical
/// 3. only entities, two or more → compound
/// 4. need words plus meaning words (or unknown words) → descriptive;
///    meaning words with no type or brand, and words that are not in any device name → descriptive
/// 5. anything else → navigational
public struct IntentClassifier: Sendable {
    public init() {}

    public func classify(_ query: ParsedQuery, matched: EntityMatcher.Output,
                         snapshot: IndexSnapshot) -> (intent: QueryIntent, reason: String, meaningTerms: Int) {
        let nonNumeric = matched.contentTerms.filter { !$0.isNumber }
        let meaningHits = nonNumeric.filter { snapshot.meaningWords.contains($0.term) }.count
        let unknownHits = nonNumeric.filter(\.isUnknown).count
        let covered = nonNumeric.filter { snapshot.vocabulary.nameTerms.contains($0.term) || $0.isPrefix }.count
        let entityCount = matched.entities.count
        // Rooms say where, not what: only types and brands name devices.
        let namedKinds = matched.entities.filter { $0.kind == .type || $0.kind == .brand }.count
        let flags = matched.flags
        let hasStatus = matched.network != nil || matched.power != nil

        if query.tokens.isEmpty && query.action == nil { return (.empty, "Nothing typed", 0) }
        if let action = query.action {
            let namesDevices = namedKinds > 0 || flags.quantifier || flags.setNoun || covered > 0
            if namesDevices || meaningHits == 0 { return (.command, "Starts with the action “\(action)”", meaningHits) }
            return (.descriptive, "The action “\(action)” is for a need, not for named devices", meaningHits)
        }
        if matched.contentTerms.isEmpty && (entityCount > 0 || hasStatus || !matched.excluded.isEmpty) {
            if flags.quantifier { return (.categorical, "Quantifier such as “all”", meaningHits) }
            if flags.plural { return (.categorical, "Plural device type", meaningHits) }
            if flags.setNoun { return (.categorical, "Set noun such as “devices”", meaningHits) }
            if entityCount <= 1 { return (.categorical, "A single type, brand or room", meaningHits) }
            if !matched.excluded.isEmpty { return (.categorical, "Exclusion", meaningHits) }
            if hasStatus { return (.categorical, "Status filter", meaningHits) }
            return (.compound, "Only types, brands and rooms", meaningHits)
        }
        if (flags.needWords > 0 || flags.setNoun) && (meaningHits > 0 || unknownHits > 0) {
            return (.descriptive, "Describes a need", meaningHits)
        }
        if namedKinds == 0 && meaningHits > 0 && covered < nonNumeric.count {
            return (.descriptive, "Meaning words that name no device", meaningHits)
        }
        return (.navigational, "Looks like a device name", meaningHits)
    }

    /// Entities become hard filters only when the user signalled a set, or "in <room>" (design doc §5).
    /// Low-confidence corrections never become filters.
    public func hardFilters(intent: QueryIntent, matched: EntityMatcher.Output, minConfidence: Double) -> HardFilters {
        var filters = HardFilters()
        let isSet = intent.isSet
        let confident = { (entity: QueryEntity) in entity.confidence >= minConfidence }
        if isSet {
            filters.types = matched.entities.filter { $0.kind == .type && confident($0) }
            filters.brands = matched.entities.filter { $0.kind == .brand && confident($0) }
        }
        filters.rooms = matched.entities.filter { $0.kind == .room && confident($0) && (isSet || $0.isHard) }
        filters.network = matched.network
        filters.power = matched.power
        filters.excluded = matched.excluded
        return filters
    }
}

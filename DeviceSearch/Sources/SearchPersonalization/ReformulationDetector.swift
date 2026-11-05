import Foundation

/// Reformulation misses (design doc §15, U03; decision D10).
///
/// A query "settles" after 1 s without typing, or on submit. A settled query followed within 5 s by a
/// different settled query, with no selection in between, is a miss. Typing on (the new query extends the
/// old one) is not a reformulation.
public struct ReformulationDetector: Sendable {
    public let window: TimeInterval
    private var last: (key: String, date: Date, selected: Bool)?

    public init(window: Duration = .seconds(5)) {
        self.window = Double(window.components.seconds) + Double(window.components.attoseconds) / 1e18
    }

    /// Records a settled query and returns the key of the query it abandoned, if any.
    public mutating func settled(_ key: String, at date: Date) -> String? {
        defer { last = (key, date, false) }
        guard let last, !last.selected, !key.isEmpty, !last.key.isEmpty, key != last.key,
              !key.hasPrefix(last.key), date.timeIntervalSince(last.date) <= window else { return nil }
        return last.key
    }

    public mutating func selected(at date: Date) {
        last?.selected = true
    }
}

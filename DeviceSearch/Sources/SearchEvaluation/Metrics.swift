import Foundation
import SearchCore

/// Ranking metrics used by the evaluation runner (design doc §17).
public enum Metrics {
    /// 1 when the expected device is ranked first.
    public static func successAt1(ranked: [DeviceID], expected: DeviceID) -> Double {
        ranked.first == expected ? 1 : 0
    }

    /// 1 / rank of the expected device within the first `k`, else 0.
    public static func reciprocalRank(ranked: [DeviceID], expected: DeviceID, k: Int = 10) -> Double {
        guard let index = ranked.prefix(k).firstIndex(of: expected) else { return 0 }
        return 1 / Double(index + 1)
    }

    /// 1 when the expected device is among the first `k` candidates.
    public static func recall(candidates: [DeviceID], expected: DeviceID, k: Int = 20) -> Double {
        candidates.prefix(k).contains(expected) ? 1 : 0
    }

    /// Normalized discounted cumulative gain at `k` with graded gains (2^gain − 1, log2 discount).
    public static func ndcg(ranked: [DeviceID], gains: [DeviceID: Int], k: Int = 5) -> Double {
        func dcg(_ values: [Int]) -> Double {
            values.prefix(k).enumerated().reduce(0) { total, item in
                total + (pow(2, Double(item.element)) - 1) / log2(Double(item.offset) + 2)
            }
        }
        let actual = dcg(ranked.map { gains[$0] ?? 0 })
        let ideal = dcg(gains.values.sorted(by: >))
        return ideal > 0 ? actual / ideal : 0
    }

    /// Precision and recall of a returned set against the expected set.
    public static func setScores(returned: [DeviceID], expected: [DeviceID]) -> (precision: Double, recall: Double) {
        let r = Set(returned)
        let e = Set(expected)
        let hits = Double(r.intersection(e).count)
        let precision = r.isEmpty ? (e.isEmpty ? 1 : 0) : hits / Double(r.count)
        let recall = e.isEmpty ? 1 : hits / Double(e.count)
        return (precision, recall)
    }

    /// The value at percentile `p` (0...100) of durations, nearest-rank method.
    public static func percentile(_ values: [Duration], _ p: Double) -> Duration {
        guard !values.isEmpty else { return .zero }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }

    /// Kendall rank correlation between two orderings of the same items (−1...1).
    public static func kendallTau<T: Hashable>(_ a: [T], _ b: [T]) -> Double {
        let common = a.filter(b.contains)
        guard common.count > 1 else { return 1 }
        let position = Dictionary(uniqueKeysWithValues: b.enumerated().map { ($0.element, $0.offset) })
        var concordant = 0
        var discordant = 0
        for i in 0..<common.count {
            for j in (i + 1)..<common.count {
                if position[common[i]]! < position[common[j]]! { concordant += 1 } else { discordant += 1 }
            }
        }
        return Double(concordant - discordant) / Double(concordant + discordant)
    }
}

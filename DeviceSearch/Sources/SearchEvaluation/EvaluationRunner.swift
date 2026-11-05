import Foundation
import SearchCore
import SearchIndex
import DeviceSearch

/// Metrics for one category of the golden set.
public struct CategoryReport: Sendable {
    public var category: GoldenCategory
    public var count: Int
    /// Device queries: share with the expected device first.
    public var successAt1: Double?
    public var mrr10: Double?
    /// Device queries: share with the expected device among the top 20 fused candidates.
    public var recall20: Double?
    /// Descriptive queries.
    public var ndcg5: Double?
    /// Set queries.
    public var setPrecision: Double?
    public var setRecall: Double?
    public var zeroResultRate: Double
    /// Share of queries where the gate wanted the model (re-rank or fallback).
    public var modelWantedRate: Double
}

public struct EvaluationReport: Sendable {
    public var categories: [CategoryReport]
    public var instantP50: Duration
    public var instantP95: Duration
    /// Up to 40 failing queries, for debugging.
    public var failures: [String]

    public func category(_ category: GoldenCategory) -> CategoryReport? {
        categories.first { $0.category == category }
    }

    /// Success@1 over navigational, typo and number queries together.
    public var navigationalSuccess: Double {
        weighted(\.successAt1, for: [.navigational, .typo, .number])
    }

    public var candidateRecall: Double {
        weighted(\.recall20, for: [.navigational, .typo, .number])
    }

    public var setPrecision: Double {
        weighted(\.setPrecision, for: [.set, .compound])
    }

    public var zeroResultRate: Double {
        let total = categories.reduce(0) { $0 + $1.count }
        guard total > 0 else { return 0 }
        return categories.reduce(0) { $0 + $1.zeroResultRate * Double($1.count) } / Double(total)
    }

    public var modelWantedRate: Double {
        let total = categories.reduce(0) { $0 + $1.count }
        guard total > 0 else { return 0 }
        return categories.reduce(0) { $0 + $1.modelWantedRate * Double($1.count) } / Double(total)
    }

    func weighted(_ metric: KeyPath<CategoryReport, Double?>, for categories: [GoldenCategory]) -> Double {
        let rows = self.categories.filter { categories.contains($0.category) && $0[keyPath: metric] != nil }
        let total = rows.reduce(0) { $0 + $1.count }
        guard total > 0 else { return 0 }
        return rows.reduce(0) { $0 + ($1[keyPath: metric] ?? 0) * Double($1.count) } / Double(total)
    }

    /// A Markdown table for logs and pull requests.
    public func markdown() -> String {
        func format(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "—" }
        var lines = ["| Category | n | S@1 | MRR@10 | R@20 | nDCG@5 | Set P | Set R | Zero | Model |",
                     "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
        for row in categories {
            lines.append("| \(row.category.rawValue) | \(row.count) | \(format(row.successAt1)) | \(format(row.mrr10)) | "
                + "\(format(row.recall20)) | \(format(row.ndcg5)) | \(format(row.setPrecision)) | "
                + "\(format(row.setRecall)) | \(format(row.zeroResultRate)) | \(format(row.modelWantedRate)) |")
        }
        lines.append("")
        lines.append("Instant phase p50 \(instantP50), p95 \(instantP95).")
        return lines.joined(separator: "\n")
    }
}

/// Runs a golden set against an engine and computes the design doc's metrics (§17).
public struct EvaluationRunner: Sendable {
    public let engine: SearchEngine

    public init(engine: SearchEngine) {
        self.engine = engine
    }

    public func run(_ queries: [GoldenQuery], mode: SearchMode = .submitted) async -> EvaluationReport {
        let snapshot = await engine.currentSnapshot
        var rows: [GoldenCategory: [(GoldenQuery, SearchSnapshot)]] = [:]
        var instant: [Duration] = []
        for query in queries {
            let phases = await engine.searchAll(query.text, mode: mode)
            guard let first = phases.first, let last = phases.last else { continue }
            instant.append(first.diagnostics.parseDuration + first.diagnostics.retrieveDuration + first.diagnostics.fuseDuration)
            rows[query.category, default: []].append((query, last))
        }

        var failures: [String] = []
        var categories: [CategoryReport] = []
        for category in GoldenCategory.allCases {
            guard let items = rows[category], !items.isEmpty else { continue }
            var success: [Double] = [], mrr: [Double] = [], recall: [Double] = [], ndcg: [Double] = []
            var precision: [Double] = [], setRecall: [Double] = []
            var zero = 0, wanted = 0
            for (query, result) in items {
                let ranked = result.noMatchesMessage == nil ? result.results.map(\.id) : []
                let candidates = result.diagnostics.topCandidates.map { snapshot.documents[$0].id }
                if ranked.isEmpty { zero += 1 }
                if let gate = result.diagnostics.gate?.outcome, gate != .skip { wanted += 1 }
                switch query.expectation {
                case .device(let expected):
                    let s = Metrics.successAt1(ranked: ranked, expected: expected)
                    success.append(s)
                    mrr.append(Metrics.reciprocalRank(ranked: ranked, expected: expected))
                    recall.append(Metrics.recall(candidates: candidates, expected: expected))
                    if s == 0, failures.count < 40 {
                        let got = ranked.first.flatMap { snapshot.document(for: $0)?.device.name } ?? "nothing"
                        let want = snapshot.document(for: expected)?.device.name ?? expected.rawValue
                        failures.append("[\(category.rawValue)] “\(query.text)” → \(got) (expected \(want))")
                    }
                case .set(let expected):
                    let scores = Metrics.setScores(returned: ranked, expected: expected)
                    precision.append(scores.precision)
                    setRecall.append(scores.recall)
                    if scores.precision < 1 || scores.recall < 1, failures.count < 40 {
                        failures.append("[\(category.rawValue)] “\(query.text)” precision \(String(format: "%.2f", scores.precision)) recall \(String(format: "%.2f", scores.recall))")
                    }
                case .graded(let gains):
                    ndcg.append(Metrics.ndcg(ranked: ranked, gains: gains))
                }
            }
            func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
            categories.append(CategoryReport(
                category: category, count: items.count, successAt1: mean(success), mrr10: mean(mrr),
                recall20: mean(recall), ndcg5: mean(ndcg), setPrecision: mean(precision), setRecall: mean(setRecall),
                zeroResultRate: Double(zero) / Double(items.count), modelWantedRate: Double(wanted) / Double(items.count)))
        }
        return EvaluationReport(categories: categories, instantP50: Metrics.percentile(instant, 50),
                                instantP95: Metrics.percentile(instant, 95), failures: failures)
    }
}

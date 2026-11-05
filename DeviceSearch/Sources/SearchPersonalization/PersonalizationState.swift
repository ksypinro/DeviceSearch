import Foundation

/// A value that halves every `halfLifeDays` (design doc §15).
public struct DecayingValue: Codable, Sendable, Equatable {
    public var value: Double
    public var updatedAt: Date

    public init(value: Double = 0, updatedAt: Date) {
        self.value = value
        self.updatedAt = updatedAt
    }

    public func value(at date: Date, halfLifeDays: Double) -> Double {
        let days = max(0, date.timeIntervalSince(updatedAt)) / 86_400
        return value * pow(0.5, days / halfLifeDays)
    }

    public mutating func add(_ amount: Double, at date: Date, halfLifeDays: Double) {
        value = value(at: date, halfLifeDays: halfLifeDays) + amount
        updatedAt = max(updatedAt, date)
    }
}

/// A query the user abandoned (reformulated within 5 s without picking anything).
public struct ReformulationMiss: Codable, Sendable, Equatable {
    public var queryKey: String
    public var date: Date
}

/// Everything personalization keeps for one home. Stored on device only, excluded from backups (§16).
/// Device ids are stored as strings so the JSON stays readable.
public struct PersonalizationState: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version = PersonalizationState.currentVersion
    /// Query key or prefix → device id → affinity (half-life 21 days).
    public var affinity: [String: [String: DecayingValue]] = [:]
    /// Device id → opens and controls (half-life 30 days).
    public var usage: [String: DecayingValue] = [:]
    /// Query key → device id → picks that no lexical evidence explained.
    public var nicknameVotes: [String: [String: Int]] = [:]
    /// Device id → learned nicknames.
    public var nicknames: [String: [String]] = [:]
    /// "device|nickname" pairs the user removed; never learned again.
    public var removedNicknames: Set<String> = []
    public var misses: [ReformulationMiss] = []

    public init() {}

    /// Drops affinities that decayed to nothing and misses older than the retention window.
    public mutating func prune(at date: Date, affinityHalfLifeDays: Double, missRetentionDays: Double) {
        for (key, devices) in affinity {
            let kept = devices.filter { $0.value.value(at: date, halfLifeDays: affinityHalfLifeDays) >= 0.01 }
            affinity[key] = kept.isEmpty ? nil : kept
        }
        let cutoff = date.addingTimeInterval(-missRetentionDays * 86_400)
        misses.removeAll { $0.date < cutoff }
    }
}

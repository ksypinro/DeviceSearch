import Foundation
import SearchCore
import SearchIndex
import DeviceSearch

/// The milestone-4 plug-in (design doc §15): selection affinity, usage priors, favorites, learned nicknames
/// and reformulation misses for one home.
///
/// - Scoped to a home: create one store per home (see `SearchEngineRegistry(makeComponents:)`).
/// - Persisted as JSON in the home's directory, excluded from backups; `clear()` deletes it (sign-out,
///   home removal).
/// - Never leaves the device and never stores anything the model produced.
public actor PersonalizationStore: PersonalSignals {
    public nonisolated let homeID: HomeID
    private let config: SearchConfig
    private let flags: any FeatureFlagProviding
    private let telemetry: any SearchTelemetry
    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private let learner: NicknameLearner
    private var detector: ReformulationDetector
    private var state: PersonalizationState

    /// - Parameter directory: the home's data directory (for example Application Support/DeviceSearch/<home>);
    ///   nil keeps everything in memory.
    public init(homeID: HomeID, directory: URL?, config: SearchConfig = .default,
                flags: any FeatureFlagProviding = FeatureFlagStore(), telemetry: any SearchTelemetry = NoopTelemetry(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.homeID = homeID
        self.config = config
        self.flags = flags
        self.telemetry = telemetry
        self.now = now
        self.fileURL = directory?.appendingPathComponent("personalization.json")
        self.learner = NicknameLearner(threshold: config.nicknameThreshold)
        self.detector = ReformulationDetector(window: config.reformulationWindow)
        self.state = Self.load(from: fileURL) ?? PersonalizationState()
    }

    // MARK: PersonalSignals

    public func personalList(for query: ParsedQuery, pool: Set<Int>, in snapshot: IndexSnapshot,
                             config: SearchConfig) async -> (list: RankedList, reasons: [Int: ReasonKind])? {
        let date = now()
        var picked: [Int: Double] = [:]
        // The query itself, a prefix of a past query (stored prefixes), or a past query plus more words.
        var keys = Set<String>()
        for key in [query.cleanKey, query.typedKey] where key.count >= config.minAffinityPrefixLength {
            keys.insert(key)
            let words = key.split(separator: " ")
            for count in 1..<max(1, words.count) { keys.insert(words.prefix(count).joined(separator: " ")) }
        }
        for key in keys {
            for (deviceID, value) in state.affinity[key] ?? [:] {
                guard let document = snapshot.document(for: DeviceID(deviceID)) else { continue }
                let score = value.value(at: date, halfLifeDays: config.affinityHalfLifeDays)
                if score >= 0.05 { picked[document.ordinal] = max(picked[document.ordinal] ?? 0, score) }
            }
        }
        var hits = picked.map { RetrievalHit(document: $0.key, score: $0.value) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.document < $1.document }
        var reasons = Dictionary(uniqueKeysWithValues: hits.map { ($0.document, ReasonKind.usualPick) })
        // Favorites among the other retrievers' hits (U05).
        let favorites = pool.filter { picked[$0] == nil && snapshot.documents[$0].device.usage?.isFavorite == true }
            .sorted { a, b in
                let (pa, pb) = (snapshot.documents[a].prior, snapshot.documents[b].prior)
                return pa != pb ? pa > pb : a < b
            }
        for ordinal in favorites {
            hits.append(RetrievalHit(document: ordinal, score: config.favoriteAffinity))
            reasons[ordinal] = .favorite
        }
        guard !hits.isEmpty else { return nil }
        return (RankedList(retriever: .personal, hits: Array(hits.prefix(config.personalLimit))), reasons)
    }

    public func indexInputs(for devices: [DeviceRecord]) async -> PersonalIndexInputs {
        let date = now()
        let local = devices.map { state.usage[$0.id.rawValue]?.value(at: date, halfLifeDays: config.usageHalfLifeDays) ?? 0 }
        // Before any local history, fall back to the backend's counts (same formula as UsagePriorProvider).
        let uses = local.contains { $0 > 0 } ? local : devices.map { Double(max(0, $0.usage?.useCount ?? 0)) }
        let denominator = log(1 + max(1, uses.max() ?? 1))
        var priors: [DeviceID: Double] = [:]
        for (device, used) in zip(devices, uses) {
            let favorite = device.usage?.isFavorite == true ? 1.0 : 0.0
            priors[device.id] = 0.7 * log(1 + used) / denominator + 0.3 * favorite
        }
        return PersonalIndexInputs(priors: priors, aliases: aliases())
    }

    public func recordSelection(_ selection: SelectionRecord) async -> PersonalChange {
        detector.selected(at: selection.date)
        let key = selection.queryKey
        guard !key.isEmpty else { return [] }
        let device = selection.device.rawValue
        // U01/U02: the query and each prefix of 2+ characters gain affinity, weighted by log2(position + 1).
        let weight = log2(Double(max(1, selection.position)) + 1)
        for prefix in Self.prefixes(of: key, minLength: config.minAffinityPrefixLength) {
            state.affinity[prefix, default: [:]][device, default: DecayingValue(updatedAt: selection.date)]
                .add(weight, at: selection.date, halfLifeDays: config.affinityHalfLifeDays)
        }
        var change: PersonalChange = []
        if flags.currentFlags().nicknamesEnabled, !selection.hadLexicalEvidence,
           learner.vote(key, device: device, in: &state) {
            telemetry.record(.nicknameLearned)
            change.insert(.aliases)
        }
        save()
        return change
    }

    public func recordSettledQuery(_ text: String, at date: Date) async {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let missed = detector.settled(key, at: date) else { return }
        state.misses.append(ReformulationMiss(queryKey: missed, date: date))
        state.prune(at: date, affinityHalfLifeDays: config.affinityHalfLifeDays,
                    missRetentionDays: config.failureRetentionDays)
        telemetry.record(.reformulationMiss)
        save()
    }

    public func recordUsage(of device: DeviceID, at date: Date) async -> PersonalChange {
        state.usage[device.rawValue, default: DecayingValue(updatedAt: date)]
            .add(1, at: date, halfLifeDays: config.usageHalfLifeDays)
        save()
        return .priors
    }

    // MARK: Settings

    /// Learned nicknames by device, for the Settings screen.
    public func learnedNicknames() -> [DeviceID: [String]] { aliases() }

    /// Removes a nickname and blocks it from being learned again. Rebuild the index afterwards.
    public func removeNickname(_ nickname: String, for device: DeviceID) -> PersonalChange {
        let id = device.rawValue
        guard state.nicknames[id]?.contains(nickname) == true else { return [] }
        state.nicknames[id]?.removeAll { $0 == nickname }
        if state.nicknames[id]?.isEmpty == true { state.nicknames[id] = nil }
        state.removedNicknames.insert(NicknameLearner.pair(id, nickname))
        state.nicknameVotes[nickname]?[id] = nil
        save()
        return .aliases
    }

    /// Recent misses (evaluation and quality dashboards; on device only).
    public func reformulationMisses(since date: Date) -> [ReformulationMiss] {
        state.misses.filter { $0.date >= date }
    }

    /// Forgets everything for this home and deletes the file (sign-out, home removal).
    public func clear() {
        state = PersonalizationState()
        detector = ReformulationDetector(window: config.reformulationWindow)
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// Deletes every home's personalization under `baseDirectory` (sign-out).
    public static func removeAll(in baseDirectory: URL) {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    // MARK: Internals

    private func aliases() -> [DeviceID: [String]] {
        var result: [DeviceID: [String]] = [:]
        for (device, names) in state.nicknames where !names.isEmpty { result[DeviceID(device)] = names }
        return result
    }

    static func prefixes(of key: String, minLength: Int) -> [String] {
        guard key.count >= minLength else { return [key] }
        return (minLength...key.count).map { String(key.prefix($0)) }
            .filter { !$0.hasSuffix(" ") }
    }

    private func save() {
        guard let fileURL else { return }
        state.prune(at: now(), affinityHalfLifeDays: config.affinityHalfLifeDays,
                    missRetentionDays: config.failureRetentionDays)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: fileURL, options: .atomic)
            Self.excludeFromBackup(fileURL)
        } catch {
            // Personalization is best-effort: a failed save never affects search.
        }
    }

    private static func load(from url: URL?) -> PersonalizationState? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let state = try? decoder.decode(PersonalizationState.self, from: data),
              state.version == PersonalizationState.currentVersion else { return nil }
        return state
    }

    private static func excludeFromBackup(_ url: URL) {
        #if canImport(Darwin)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
        #endif
    }
}

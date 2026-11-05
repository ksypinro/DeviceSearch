@preconcurrency import CoreSpotlight
import Foundation
import Synchronization
import SearchCore
import SearchIndex
import DeviceSearch

/// Donates the active home's devices to Spotlight after every snapshot swap (design doc §14 Y04).
/// Only changed devices are re-indexed; removed devices are deleted. Behind the `spotlightEnabled` flag.
///
/// Items are built by `SpotlightItemMapping` and carry their `DeviceEntity`, so Siri and Shortcuts see them too.
/// Locks, cameras, doorbells and garage doors go in a second index that is unreadable while the device is locked.
/// What each index holds is saved to `stateURL`, so a device deleted while the app was closed (or a home
/// switched on an earlier launch) is removed on the next sync. Writes run one at a time.
///
/// The saved state can still drift from Spotlight: the system may lose its index or fail to index items. Its
/// index delegate requests are honoured (`SpotlightIndexDelegate`), and the first snapshot after `follow` checks
/// that every catalog item the state lists is still there.
actor SpotlightIndexer {
    private enum Partition: String, CaseIterable {
        case catalog, secure
    }

    /// One index's contents as last written.
    private struct PartitionState: Codable {
        var homeID: String?
        /// Device id → `SpotlightItemMapping.signature`.
        var signatures: [String: String]
        /// When every item was last donated; all are donated again before they can expire.
        var donatedAt: Date

        static var empty: PartitionState { PartitionState(homeID: nil, signatures: [:], donatedAt: Date()) }
    }

    private struct SavedState: Codable {
        var schema: Int
        var partitions: [String: PartitionState]
    }

    private static let redonationInterval: TimeInterval = 60 * 60 * 24 * 30
    /// A dimmer slider must not write to the index on every tick.
    private static let usageCoalescing: Duration = .seconds(5)

    private let catalog: CSSearchableIndex
    private let secure: CSSearchableIndex
    /// The unprotected index earlier builds donated entities to; emptied whenever the catalog starts over.
    private let legacy: CSSearchableIndex
    private let flags: any FeatureFlagProviding
    private let stateURL: URL
    /// A partition missing here has unknown contents (no saved state, an older schema, a failed delete): its next
    /// write starts by deleting every item.
    private var known: [Partition: PartitionState]
    private var followedHome: HomeID?
    private var latest: IndexSnapshot?
    private var following: Task<Void, Never>?
    private var lastWrite: Task<Void, Never>?
    private var lastUsed: [DeviceID: Date] = [:]
    private var pendingUsage: [DeviceID: Date] = [:]
    private var usageFlush: Task<Void, Never>?
    /// Held here because `indexDelegate` is weak.
    private let delegate = SpotlightIndexDelegate()
    private var checkedSinceFollow = false
    /// Identifiers the last write sent. Spotlight makes items searchable a little after they are sent, so the
    /// self-check does not count these as missing.
    private var justSent: Set<String> = []

    init(indexName: String, stateURL: URL, flags: any FeatureFlagProviding) {
        self.catalog = CSSearchableIndex(name: "\(indexName).catalog", protectionClass: .completeUntilFirstUserAuthentication)
        self.secure = CSSearchableIndex(name: "\(indexName).secure", protectionClass: .complete)
        self.legacy = CSSearchableIndex(name: indexName)
        self.flags = flags
        self.stateURL = stateURL
        self.known = Self.load(from: stateURL)
        catalog.indexDelegate = delegate
        secure.indexDelegate = delegate
        delegate.attach(self)
    }

    /// Follows a home's engine; its first snapshot replaces the previous home's entries.
    func follow(_ engine: SearchEngine) async {
        following?.cancel()
        followedHome = engine.homeID
        latest = nil
        checkedSinceFollow = false
        let updates = await engine.snapshotUpdates()
        following = Task { [weak self] in
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                await self?.receive(snapshot)
            }
        }
    }

    /// Call after the flags change (remote config refresh, a settings toggle): off deletes every entry, on
    /// indexes the followed home again.
    func flagsDidChange() async {
        await serialized { await $0.write() }
    }

    /// The device was opened or controlled: its result's last-used date moves forward, coalesced per device.
    func noteUsed(_ device: DeviceID, at date: Date = Date()) {
        lastUsed[device] = date
        pendingUsage[device] = date
        guard usageFlush == nil else { return }
        usageFlush = Task { [weak self] in
            try? await Task.sleep(for: Self.usageCoalescing)
            await self?.flushUsage()
        }
    }

    /// The home left the account: its entries are deleted from both indexes.
    func remove(_ homeID: HomeID) async {
        if followedHome == homeID { stopFollowing() }
        await serialized { await $0.deleteDomain(of: homeID) }
    }

    /// Sign-out: stops following and deletes every entry.
    func removeAll() async {
        stopFollowing()
        usageFlush?.cancel()
        usageFlush = nil
        pendingUsage = [:]
        lastUsed = [:]
        await serialized { await $0.clear() }
    }

    // MARK: Recovery

    /// Spotlight lost its index (delegate request): every item is sent again, from the followed home or, when
    /// none is open yet, on the next `follow`.
    func reindexAll() async {
        await serialized { indexer in
            await indexer.forget(nil)
            await indexer.write()
        }
    }

    /// Spotlight could not index these items (delegate request): they are sent again.
    func reindex(_ identifiers: [String]) async {
        let devices = Set(identifiers.compactMap { SpotlightItemMapping.deviceID(fromIdentifier: $0)?.rawValue })
        await serialized { indexer in
            await indexer.forget(devices)
            await indexer.write()
        }
    }

    /// What full items are built from, for Spotlight to read on demand (iOS 18.4+; `SpotlightSearchTool` reads
    /// items this way). The caller builds them with `SpotlightItemMapping.item(for:homeID:lastUsed:)`.
    func itemSources(for identifiers: [String]) -> [(document: SearchDocument, homeID: HomeID, lastUsed: Date?)] {
        guard let snapshot = latest else { return [] }
        return identifiers.compactMap { identifier in
            guard let device = SpotlightItemMapping.deviceID(fromIdentifier: identifier),
                  let document = snapshot.document(for: device) else { return nil }
            return (document, snapshot.homeID, lastUsed[device])
        }
    }

    /// The same, limited to the items that live in the index with this protection class: `.complete` holds the
    /// sensitive devices (locks, cameras, …), the other class everything else.
    func itemSources(for identifiers: [String], protectionClass: FileProtectionType)
        -> [(document: SearchDocument, homeID: HomeID, lastUsed: Date?)] {
        let wantsSecure = protectionClass == .complete
        return itemSources(for: identifiers).filter { SpotlightItemMapping.isSensitive($0.document) == wantsSecure }
    }

    /// Sends again every catalog item the saved state lists but Spotlight no longer returns. Runs once after
    /// each `follow`; the secure index is left out, since it is unreadable while the device is locked.
    func restoreMissingItems() async {
        await serialized { await $0.restoreMissing() }
    }

    /// Waits until the writes queued so far have finished.
    func settled() async {
        await lastWrite?.value
    }

    private func receive(_ snapshot: IndexSnapshot) async {
        guard snapshot.homeID == followedHome else { return }
        latest = snapshot
        await serialized { await $0.write() }
        if !checkedSinceFollow {
            checkedSinceFollow = true
            await serialized { await $0.restoreMissing() }
        }
    }

    private func stopFollowing() {
        following?.cancel()
        following = nil
        followedHome = nil
        latest = nil
    }

    private func index(_ partition: Partition) -> CSSearchableIndex {
        switch partition {
        case .catalog: catalog
        case .secure: secure
        }
    }

    /// Runs index writes one at a time, each after the previous one (Core Spotlight wants a single writer).
    private func serialized(_ work: @escaping @Sendable (SpotlightIndexer) async -> Void) async {
        let previous = lastWrite
        let next = Task { [self] in
            await previous?.value
            await work(self)
        }
        lastWrite = next
        await next.value
    }

    // MARK: Writes (only through `serialized`)

    /// One partition's difference from what it holds.
    private struct Plan {
        var removed: [String]
        var changed: [CSSearchableItem]
        var state: PartitionState
    }

    /// Brings both indexes in line with the flag and the latest snapshot.
    ///
    /// Deletes are scoped to the app's store for a protection class, not to one named index (the Simulator keeps
    /// every class in one store), so a partition with unknown contents makes every partition start over, and
    /// all deletes run before any write: a device moving between partitions is removed, then added.
    private func write() async {
        justSent = []
        guard flags.currentFlags().spotlightEnabled else { return await clear() }
        guard let snapshot = latest else { return }
        if Partition.allCases.contains(where: { known[$0] == nil }), !(await startOver()) { return save() }
        var documents: [Partition: [SearchDocument]] = [:]
        for document in snapshot.documents {
            documents[SpotlightItemMapping.isSensitive(document) ? .secure : .catalog, default: []].append(document)
        }
        var plans: [Partition: Plan] = [:]
        for partition in Partition.allCases {
            guard let previous = known[partition] else { continue }
            plans[partition] = plan(documents[partition] ?? [], from: previous, homeID: snapshot.homeID)
        }
        // Spotlight is best effort: a partition whose write fails keeps its old state and the next snapshot
        // retries the difference. The secure index refuses writes while the device is locked.
        var failed: Set<Partition> = []
        for (partition, plan) in plans where !plan.removed.isEmpty {
            do { try await index(partition).deleteSearchableItems(withIdentifiers: plan.removed) } catch { failed.insert(partition) }
        }
        for (partition, plan) in plans where !plan.changed.isEmpty && !failed.contains(partition) {
            do {
                try await index(partition).indexSearchableItems(plan.changed)
                justSent.formUnion(plan.changed.map(\.uniqueIdentifier))
            } catch {
                failed.insert(partition)
            }
        }
        for (partition, plan) in plans where !failed.contains(partition) { known[partition] = plan.state }
        save()
    }

    /// Drops devices from the saved state so the next write sends them again; nil drops everything, so the next
    /// write starts over. Saved at once, so a request made before any home is open survives a relaunch.
    private func forget(_ devices: Set<String>?) {
        if let devices {
            for partition in Partition.allCases {
                guard var state = known[partition] else { continue }
                state.signatures = state.signatures.filter { !devices.contains($0.key) }
                known[partition] = state
            }
        } else {
            known = [:]
        }
        save()
    }

    private func restoreMissing() async {
        guard flags.currentFlags().spotlightEnabled, latest != nil,
              let listed = known[.catalog]?.signatures.keys, !listed.isEmpty,
              let present = await Self.indexedIdentifiers() else { return }
        let missing = Set(listed.filter {
            let identifier = SpotlightItemMapping.identifier(for: DeviceID($0))
            return !present.contains(identifier) && !justSent.contains(identifier)
        })
        guard !missing.isEmpty else { return }
        forget(missing)
        await write()
    }

    /// Identifiers of every item of this app that Spotlight currently returns, or nil when the query fails.
    static func indexedIdentifiers() async -> Set<String>? {
        let context = CSSearchQueryContext()
        context.fetchAttributes = []
        let query = CSSearchQuery(queryString: "title == \"*\"", queryContext: context)
        query.protectionClasses = [.completeUntilFirstUserAuthentication, .complete]
        var identifiers = Set<String>()
        do {
            for try await result in query.results { identifiers.insert(result.item.uniqueIdentifier) }
        } catch {
            return nil
        }
        return identifiers
    }

    private func plan(_ documents: [SearchDocument], from previous: PartitionState, homeID: HomeID) -> Plan {
        // Everything is donated again for another home (items carry its domain) or before items expire.
        let redonate = previous.homeID != homeID.rawValue
            || Date().timeIntervalSince(previous.donatedAt) > Self.redonationInterval
        var current: [String: String] = [:]
        var changed: [CSSearchableItem] = []
        for document in documents {
            let signature = SpotlightItemMapping.signature(of: document)
            current[document.id.rawValue] = signature
            if redonate || previous.signatures[document.id.rawValue] != signature {
                changed.append(SpotlightItemMapping.item(for: document, homeID: homeID, lastUsed: lastUsed[document.id]))
            }
        }
        let removed = previous.signatures.keys.filter { current[$0] == nil }
            .map { SpotlightItemMapping.identifier(for: DeviceID($0)) }
        return Plan(removed: removed, changed: changed,
                    state: PartitionState(homeID: homeID.rawValue, signatures: current,
                                          donatedAt: redonate ? Date() : previous.donatedAt))
    }

    /// Empties every index, including the legacy one. Returns false (contents unknown) when a delete fails.
    private func startOver() async -> Bool {
        do {
            try await legacy.deleteAllSearchableItems()
            for partition in Partition.allCases { try await index(partition).deleteAllSearchableItems() }
        } catch {
            for partition in Partition.allCases { known[partition] = nil }
            return false
        }
        for partition in Partition.allCases { known[partition] = .empty }
        return true
    }

    private func clear() async {
        for partition in Partition.allCases where known[partition]?.signatures.isEmpty != true {
            do {
                if partition == .catalog { try await legacy.deleteAllSearchableItems() }
                try await index(partition).deleteAllSearchableItems()
                known[partition] = .empty
            } catch {
                known[partition] = nil
            }
        }
        save()
    }

    private func deleteDomain(of homeID: HomeID) async {
        for partition in Partition.allCases {
            let held = known[partition]?.homeID == homeID.rawValue
            do {
                try await index(partition).deleteSearchableItems(withDomainIdentifiers: [SpotlightItemMapping.domain(for: homeID)])
                if held { known[partition] = .empty }
            } catch {
                if held { known[partition] = nil }
            }
        }
        save()
    }

    private func flushUsage() async {
        usageFlush = nil
        let dates = pendingUsage
        pendingUsage = [:]
        await serialized { await $0.patchUsage(dates) }
    }

    private func patchUsage(_ dates: [DeviceID: Date]) async {
        guard flags.currentFlags().spotlightEnabled else { return }
        for partition in Partition.allCases {
            guard let state = known[partition], let homeID = state.homeID.map({ HomeID($0) }) else { continue }
            let patches = dates.filter { state.signatures[$0.key.rawValue] != nil }
                .map { SpotlightItemMapping.usagePatch(for: $0.key, homeID: homeID, date: $0.value) }
            if !patches.isEmpty { try? await index(partition).indexSearchableItems(patches) }
        }
    }

    // MARK: Saved state

    private static func load(from url: URL) -> [Partition: PartitionState] {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(SavedState.self, from: data),
              saved.schema == SpotlightItemMapping.schemaVersion else { return [:] }
        var known: [Partition: PartitionState] = [:]
        for partition in Partition.allCases { known[partition] = saved.partitions[partition.rawValue] }
        return known
    }

    private func save() {
        let saved = SavedState(schema: SpotlightItemMapping.schemaVersion,
                               partitions: Dictionary(uniqueKeysWithValues: known.map { ($0.key.rawValue, $0.value) }))
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: stateURL, options: .atomic)
        } catch {
            // A stale file would hide entries from the next launch; without one it starts with a full delete.
            try? FileManager.default.removeItem(at: stateURL)
        }
    }
}

/// Core Spotlight's requests to the indexer: send everything again after it lost its index, send items it could
/// not index, and hand out full items on demand. Requests can arrive at launch before any home is open; the
/// indexer then remembers them until it follows one. (An index app extension would also serve them while the app
/// is not running.)
final class SpotlightIndexDelegate: NSObject, CSSearchableIndexDelegate, Sendable {
    private struct Target: Sendable {
        weak var indexer: SpotlightIndexer?
    }

    private let target = Mutex(Target())

    func attach(_ indexer: SpotlightIndexer) {
        target.withLock { $0.indexer = indexer }
    }

    private var indexer: SpotlightIndexer? { target.withLock { $0.indexer } }

    func searchableIndex(_ searchableIndex: CSSearchableIndex,
                         reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void) {
        nonisolated(unsafe) let acknowledge = acknowledgementHandler
        let indexer = indexer
        Task {
            await indexer?.reindexAll()
            acknowledge()
        }
    }

    func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexSearchableItemsWithIdentifiers identifiers: [String],
                         acknowledgementHandler: @escaping () -> Void) {
        nonisolated(unsafe) let acknowledge = acknowledgementHandler
        let indexer = indexer
        Task {
            await indexer?.reindex(identifiers)
            acknowledge()
        }
    }

    func searchableItems(forIdentifiers identifiers: [String],
                         searchableItemsHandler: @escaping ([CSSearchableItem]) -> Void) {
        nonisolated(unsafe) let handler = searchableItemsHandler
        let indexer = indexer
        Task {
            let sources = await indexer?.itemSources(for: identifiers) ?? []
            handler(sources.map { SpotlightItemMapping.item(for: $0.document, homeID: $0.homeID, lastUsed: $0.lastUsed) })
        }
    }

    /// iOS 27 asks per protection class, so an item never comes back from the wrong index.
    @available(iOS 27.0, macOS 27.0, *)
    func searchableItems(forIdentifiers identifiers: [String], protectionClass: FileProtectionType,
                         searchableItemsHandler: @escaping ([CSSearchableItem]) -> Void) {
        nonisolated(unsafe) let handler = searchableItemsHandler
        let indexer = indexer
        Task {
            let sources = await indexer?.itemSources(for: identifiers, protectionClass: protectionClass) ?? []
            handler(sources.map { SpotlightItemMapping.item(for: $0.document, homeID: $0.homeID, lastUsed: $0.lastUsed) })
        }
    }
}

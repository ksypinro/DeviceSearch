import Foundation
import Synchronization
import SearchCore
import SearchKnowledge
import DeviceSearch
import SearchSemantic
import SearchRerank
import SearchPersonalization
import DeviceSearchUI

/// The app's search services: created once at launch, registered with `AppDependencyManager`, and shared by the
/// search screen, App Intents, Siri, Shortcuts and Spotlight.
final class AppSearchServices: Sendable {
    let knowledge: KnowledgeBase
    let flags: FeatureFlagStore
    let telemetry: any SearchTelemetry
    let registry: SearchEngineRegistry
    let spotlight: SpotlightIndexer
    let personalization: PersonalizationStores
    private let activeHome = Mutex<HomeID?>(nil)
    /// A home opening at launch; intents that arrive first wait for it.
    private let opening = Mutex<Task<Void, Never>?>(nil)
    private let shortcutRefresh = Mutex<Task<Void, Never>?>(nil)
    private let baseDirectory: URL

    init(subsystem: String = Bundle.main.bundleIdentifier ?? "app") throws {
        let knowledge = try KnowledgeBase.bundled()
        let flags = FeatureFlagStore(.allOn)
        let telemetry: any SearchTelemetry = OSLogTelemetry(subsystem: subsystem)
        let baseDirectory = URL.applicationSupportDirectory.appending(path: "DeviceSearch", directoryHint: .isDirectory)
        let model = FoundationModelsClient()
        let refiner = LLMReranker(client: model)
        let rewriter = LLMQueryRewriter(client: model)
        let personalization = PersonalizationStores(baseDirectory: baseDirectory, flags: flags, telemetry: telemetry)
        self.personalization = personalization
        self.spotlight = SpotlightIndexer(indexName: "\(subsystem).devices",
                                          stateURL: baseDirectory.appending(path: "spotlight-index.json"), flags: flags)
        self.knowledge = knowledge
        self.flags = flags
        self.telemetry = telemetry
        self.baseDirectory = baseDirectory
        self.registry = SearchEngineRegistry { homeID in
            var components = DeviceSearchComponents(knowledge: knowledge, flags: flags, telemetry: telemetry)
            components.meaning = AppSearchServices.makeMeaning(for: homeID, knowledge: knowledge,
                                                               directory: AppSearchServices.directory(for: homeID, in: baseDirectory),
                                                               telemetry: telemetry)
            components.refiner = refiner
            components.rewriter = rewriter
            components.personal = personalization.store(for: homeID)
            return components
        }
    }

    /// The home's meaning provider: Apple's contextual embeddings, or the lexicon embedding when the system has
    /// no model for the language (decision D06). Vectors are cached per home and model.
    static func makeMeaning(for homeID: HomeID, knowledge: KnowledgeBase, directory: URL,
                            telemetry: any SearchTelemetry) -> MeaningRetrievalProvider {
        let embedder: any TextEmbedding = NLContextualEmbedder(language: .english) ?? LexiconEmbedding(knowledge: knowledge)
        let cacheURL = directory.appending(path: "embeddings-\(safe(embedder.modelVersion)).bin")
        return MeaningRetrievalProvider(embedder: embedder, knowledge: knowledge, cacheURL: cacheURL, telemetry: telemetry)
    }

    static func directory(for homeID: HomeID, in base: URL) -> URL {
        base.appending(path: safe(homeID.rawValue), directoryHint: .isDirectory)
    }

    static func safe(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "home"
    }

    // MARK: Homes

    /// Opens a home's search (design doc §11 X08) and makes it the active one for intents and Spotlight.
    @discardableResult
    func open(_ homeID: HomeID, devices: [DeviceRecord], events: AsyncStream<DeviceEvent>?) async -> HomeSearch {
        // A second open of a home still building would start a second consumer of its event stream.
        if let opening = opening.withLock({ $0 }) { await opening.value }
        return await openNow(homeID, devices: devices, events: events)
    }

    private func openNow(_ homeID: HomeID, devices: [DeviceRecord], events: AsyncStream<DeviceEvent>?) async -> HomeSearch {
        let home = await registry.open(homeID, devices: devices, events: events)
        activeHome.withLock { $0 = homeID }
        await spotlight.follow(home.engine)
        await refreshShortcutParameters(following: home.engine)
        return home
    }

    /// Opens a home at launch without waiting. A shortcut run from Siri or Spotlight starts the app in the
    /// background, before any screen exists, so its entity lookups need the home open already.
    func openAtLaunch(_ homeID: HomeID, devices: [DeviceRecord], events: AsyncStream<DeviceEvent>?) {
        let task = Task { _ = await self.openNow(homeID, devices: devices, events: events) }
        opening.withLock { $0 = task }
    }

    /// App Shortcut phrases list suggested devices and rooms by name, so they are refreshed when the catalogue
    /// changes. Status and usage changes do not publish snapshots.
    private func refreshShortcutParameters(following engine: SearchEngine) async {
        let updates = await engine.snapshotUpdates()
        let task = Task {
            var catalogue: [String] = []
            for await snapshot in updates {
                let current = snapshot.documents.map { "\($0.id.rawValue)|\($0.device.name)|\($0.device.room ?? "")" }.sorted()
                guard current != catalogue else { continue }
                catalogue = current
                DeviceSearchShortcuts.updateAppShortcutParameters()
            }
        }
        shortcutRefresh.withLock { previous in
            previous?.cancel()
            previous = task
        }
    }

    func close(_ homeID: HomeID) async {
        await registry.close(homeID)
        activeHome.withLock { if $0 == homeID { $0 = nil } }
    }

    /// The home was removed from the account: its search data goes with it (design doc §16 Z02).
    func removeHome(_ homeID: HomeID) async {
        await close(homeID)
        await spotlight.remove(homeID)
        await personalization.clear(homeID)
        try? FileManager.default.removeItem(at: Self.directory(for: homeID, in: baseDirectory))
    }

    /// Sign-out: close every home and delete embeddings, personalization and Spotlight entries.
    func signOut() async {
        await registry.closeAll()
        activeHome.withLock { $0 = nil }
        await personalization.clearAll()
        await spotlight.removeAll()
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    /// Call after updating `flags` (remote config refresh, settings): Spotlight follows the kill switch at once.
    func flagsDidChange() async {
        await spotlight.flagsDidChange()
    }

    func activeSearch() async -> HomeSearch? {
        if let opening = opening.withLock({ $0 }) { await opening.value }
        guard let homeID = activeHome.withLock({ $0 }) else { return nil }
        return await registry.search(for: homeID)
    }

    /// Room names of the active home's devices, sorted.
    func rooms() async -> [String] {
        guard let engine = await activeSearch()?.engine else { return [] }
        return Set(await engine.allDevices().compactMap(\.room)).sorted()
    }

    /// Lights in a room of the active home.
    func lights(inRoom room: String) async -> [DeviceID] {
        guard let engine = await activeSearch()?.engine else { return [] }
        return await engine.allDevices()
            .filter { $0.room == room && knowledge.typeCard(for: $0.type).id == "light" }
            .map(\.id)
    }

    /// Live status of devices in the active home, as the event bridge last reported it.
    func statuses(for devices: [DeviceID]) async -> [DeviceID: DeviceStatus] {
        guard let engine = await activeSearch()?.engine else { return [:] }
        var statuses: [DeviceID: DeviceStatus] = [:]
        for record in await engine.devices(withIDs: devices) {
            if let status = record.status { statuses[record.id] = status }
        }
        return statuses
    }

    // MARK: System surfaces (fast path, never the model — design doc §14 Y02, Y03)

    func entities(for identifiers: [String]) async -> [DeviceEntity] {
        guard let engine = await activeSearch()?.engine else { return [] }
        return await engine.devices(withIDs: identifiers.map { DeviceID($0) }).map { DeviceEntity(record: $0, knowledge: knowledge) }
    }

    func entities(matching text: String, limit: Int) async -> [DeviceEntity] {
        guard let engine = await activeSearch()?.engine else { return [] }
        return await engine.topResults(for: text, limit: limit).map { DeviceEntity(result: $0) }
    }

    func suggestedEntities(limit: Int) async -> [DeviceEntity] {
        guard let engine = await activeSearch()?.engine else { return [] }
        return await engine.favoritesAndRecents(limit: limit).map { DeviceEntity(result: $0) }
    }

    /// Call when a device is opened or controlled anywhere in the app (usage prior, design doc §15 U04).
    func recordUsage(of device: DeviceID) async {
        await spotlight.noteUsed(device)
        await activeSearch()?.engine.recordUsage(of: device)
    }
}

/// One personalization store per home, created on demand (design doc §16 Z02).
final class PersonalizationStores: Sendable {
    private let baseDirectory: URL
    private let flags: FeatureFlagStore
    private let telemetry: any SearchTelemetry
    private let stores = Mutex<[HomeID: PersonalizationStore]>([:])

    init(baseDirectory: URL, flags: FeatureFlagStore, telemetry: any SearchTelemetry) {
        self.baseDirectory = baseDirectory
        self.flags = flags
        self.telemetry = telemetry
    }

    func store(for homeID: HomeID) -> PersonalizationStore {
        stores.withLock { stores in
            if let existing = stores[homeID] { return existing }
            let store = PersonalizationStore(homeID: homeID, directory: AppSearchServices.directory(for: homeID, in: baseDirectory),
                                             flags: flags, telemetry: telemetry)
            stores[homeID] = store
            return store
        }
    }

    func clear(_ homeID: HomeID) async {
        let store = stores.withLock { $0.removeValue(forKey: homeID) }
        await store?.clear()
    }

    func clearAll() async {
        let all = stores.withLock { stores -> [PersonalizationStore] in
            defer { stores.removeAll() }
            return Array(stores.values)
        }
        for store in all { await store.clear() }
        PersonalizationStore.removeAll(in: baseDirectory)
    }
}

/// The Settings screen lists and removes learned nicknames through this protocol.
extension PersonalizationStore: @retroactive NicknameManaging {}

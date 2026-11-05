import SearchCore
import SearchIndex
import SearchKnowledge
import SearchText

/// Everything optional a home's search can use. Milestone 1 passes only the required values;
/// later milestones add plug-ins without touching the engine.
///
/// `meaning` and `personal` hold per-home state (embedding cache, selection history): give each home its own
/// instances through `SearchEngineRegistry(makeComponents:)`. `refiner` and `rewriter` are stateless and shared.
public struct DeviceSearchComponents: Sendable {
    public var knowledge: KnowledgeBase
    public var config: SearchConfig
    public var flags: any FeatureFlagProviding
    public var telemetry: any SearchTelemetry
    public var segmenter: any WordSegmenting
    /// Milestone 2.
    public var meaning: (any MeaningRetrieval)?
    /// Milestone 3.
    public var refiner: (any ResultRefining)?
    public var rewriter: (any QueryRewriting)?
    /// Milestone 4.
    public var personal: (any PersonalSignals)?

    public init(knowledge: KnowledgeBase, config: SearchConfig = .default,
                flags: any FeatureFlagProviding = FeatureFlagStore(),
                telemetry: any SearchTelemetry = NoopTelemetry(),
                segmenter: any WordSegmenting = PassthroughSegmenter(),
                meaning: (any MeaningRetrieval)? = nil, refiner: (any ResultRefining)? = nil,
                rewriter: (any QueryRewriting)? = nil, personal: (any PersonalSignals)? = nil) {
        self.knowledge = knowledge
        self.config = config
        self.flags = flags
        self.telemetry = telemetry
        self.segmenter = segmenter
        self.meaning = meaning
        self.refiner = refiner
        self.rewriter = rewriter
        self.personal = personal
    }
}

/// The engine and the index sync of one home.
public struct HomeSearch: Sendable {
    public let engine: SearchEngine
    public let sync: IndexSync

    public init(engine: SearchEngine, sync: IndexSync) {
        self.engine = engine
        self.sync = sync
    }

    /// Builds the first snapshot from `devices` and wires the engine and sync for `homeID`.
    public static func make(homeID: HomeID, devices: [DeviceRecord], components: DeviceSearchComponents) async -> HomeSearch {
        let builder = IndexBuilder(knowledge: components.knowledge,
                                   pipeline: components.knowledge.makePipeline(segmenter: components.segmenter),
                                   maxPhraseLength: components.config.maxPhraseLength)
        let ordered = devices.sorted { $0.id < $1.id }
        let inputs = await components.personal?.indexInputs(for: ordered)
        let first = builder.build(homeID: homeID, devices: ordered, generation: 1,
                                  priors: inputs?.priors.map { StaticPriors(values: $0) },
                                  aliases: inputs.map { StaticAliases(values: $0.aliases) },
                                  vectorSource: components.meaning?.vectorSource)
        let engine = SearchEngine(snapshot: first, config: components.config, flags: components.flags,
                                  telemetry: components.telemetry, meaning: components.meaning,
                                  refiner: components.refiner, rewriter: components.rewriter,
                                  personal: components.personal)
        let sync = IndexSync(engine: engine, builder: builder, initialDevices: ordered, generation: 1,
                             config: components.config, telemetry: components.telemetry,
                             meaning: components.meaning, personal: components.personal)
        await engine.onRebuildNeeded { [weak sync] in await sync?.requestRebuild() }
        await engine.swap(first)
        return HomeSearch(engine: engine, sync: sync)
    }
}

/// One search per home (design doc §11): built when a home opens, dropped when it closes.
public actor SearchEngineRegistry {
    /// Builds the components for one home: shared knowledge, flags, telemetry and refiner, plus that home's own
    /// meaning provider (embedding cache) and personalization store.
    public typealias ComponentsFactory = @Sendable (HomeID) async -> DeviceSearchComponents

    private let makeComponents: ComponentsFactory
    private var homes: [HomeID: HomeSearch] = [:]

    public init(makeComponents: @escaping ComponentsFactory) {
        self.makeComponents = makeComponents
    }

    /// Every home gets the same components (milestone 1: no per-home plug-ins yet).
    public init(components: DeviceSearchComponents) {
        self.makeComponents = { _ in components }
    }

    /// Opens (or returns) the search for a home. `events` keeps the index in sync until the home closes.
    @discardableResult
    public func open(_ homeID: HomeID, devices: [DeviceRecord], events: AsyncStream<DeviceEvent>? = nil) async -> HomeSearch {
        if let existing = homes[homeID] { return existing }
        let home = await HomeSearch.make(homeID: homeID, devices: devices, components: await makeComponents(homeID))
        if let events { await home.sync.start(events) }
        homes[homeID] = home
        return home
    }

    public func search(for homeID: HomeID) -> HomeSearch? { homes[homeID] }

    public func close(_ homeID: HomeID) async {
        await homes[homeID]?.sync.stop()
        homes[homeID] = nil
    }

    public func closeAll() async {
        for home in homes.values { await home.sync.stop() }
        homes.removeAll()
    }

    public var openHomes: [HomeID] { homes.keys.sorted() }
}

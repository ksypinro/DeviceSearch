import Foundation
import SearchCore
import SearchIndex

/// The data plane (design doc §11): a projection of device events into index snapshots.
///
/// - Searchable changes are coalesced for 250 ms, then every lexical structure is rebuilt (5–15 ms at 500 devices)
///   and swapped into the engine atomically.
/// - Status and usage changes take a fast path and never rebuild.
/// - Rebuilds start warm: cached embeddings come from the meaning plug-in's vector source.
public actor IndexSync {
    private let engine: SearchEngine
    private let builder: IndexBuilder
    private let config: SearchConfig
    private let telemetry: any SearchTelemetry
    private let meaning: (any MeaningRetrieval)?
    private let personal: (any PersonalSignals)?
    private var devices: [DeviceID: DeviceRecord] = [:]
    private var generation: UInt64
    private var pending: Task<Void, Never>?
    private var consumer: Task<Void, Never>?

    public init(engine: SearchEngine, builder: IndexBuilder, initialDevices: [DeviceRecord] = [],
                generation: UInt64 = 0, config: SearchConfig = .default,
                telemetry: any SearchTelemetry = NoopTelemetry(),
                meaning: (any MeaningRetrieval)? = nil, personal: (any PersonalSignals)? = nil) {
        self.engine = engine
        self.builder = builder
        self.config = config
        self.telemetry = telemetry
        self.meaning = meaning
        self.personal = personal
        self.generation = generation
        for device in initialDevices { devices[device.id] = device }
    }

    /// Consumes an event stream until it ends or `stop()` is called.
    public func start(_ events: AsyncStream<DeviceEvent>) {
        consumer?.cancel()
        consumer = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                await self.apply(event)
            }
        }
    }

    public func stop() {
        consumer?.cancel()
        consumer = nil
        pending?.cancel()
        pending = nil
    }

    public func apply(_ event: DeviceEvent) async {
        switch event {
        case .upserted(let device):
            devices[device.id] = device
            scheduleRebuild()
        case .removed(let id):
            devices[id] = nil
            scheduleRebuild()
        case .replacedAll(let all):
            devices = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            scheduleRebuild()
        case .statusChanged(let id, let status):
            guard devices[id] != nil else { return }
            devices[id]?.status = status
            await engine.applyStatus(status, for: id)
        case .usageChanged(let id, let usage):
            guard devices[id] != nil else { return }
            devices[id]?.usage = usage
            let all = Array(devices.values)
            if let personal, let priors = await personal.indexInputs(for: all).priors {
                await engine.applyPriors(priors)
            } else {
                await engine.applyPriors(UsagePriorProvider().priors(for: all))
            }
        }
    }

    /// Coalesced rebuild with unchanged devices (a learned nickname must reach the index).
    public func requestRebuild() {
        scheduleRebuild()
    }

    /// Rebuilds immediately, skipping the coalescing delay (initial load, tests).
    public func rebuildNow() async {
        pending?.cancel()
        pending = nil
        await rebuild()
    }

    public var deviceCount: Int { devices.count }

    private func scheduleRebuild() {
        pending?.cancel()
        let delay = config.rebuildCoalescing
        pending = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.rebuild()
        }
    }

    private func rebuild() async {
        let ordered = devices.values.sorted { $0.id < $1.id }
        generation += 1
        let inputs = await personal?.indexInputs(for: ordered)
        let snapshot = builder.build(
            homeID: engine.homeID, devices: ordered, generation: generation,
            priors: inputs?.priors.map { StaticPriors(values: $0) },
            aliases: inputs.map { StaticAliases(values: $0.aliases) },
            vectorSource: meaning?.vectorSource)
        telemetry.record(.indexRebuilt(documents: snapshot.count, duration: snapshot.buildDuration))
        await engine.swap(snapshot)
    }
}

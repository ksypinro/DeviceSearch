#if canImport(FoundationModels) && arch(arm64)
import CoreSpotlight
import Foundation
import FoundationModels
import Synchronization
import SearchCore
// `SpotlightSearchTool` comes from the CoreSpotlight + FoundationModels overlay (iOS 27), whose Intel simulator
// slice is empty, so this file is built for arm64 only.

/// What `DeviceAsk` found: the model's reply and the devices its searches returned, best first.
struct DeviceAnswer: Sendable {
    var text: String
    var devices: [DeviceID]
    /// Set when the model could not answer; `text` is then empty.
    var failure: String?
    /// The underlying error, for logs and debugging screens.
    var detail: String?
}

/// Answers questions about the home ("which lights are still on?", "is anything offline in the garage?") with
/// Apple Intelligence and Spotlight's own retrieval tool (iOS 27). The model writes Spotlight queries over the
/// items `SpotlightIndexer` donates; a custom stage filters them by the app's live status, which Spotlight does
/// not hold. It only looks things up: switching devices stays with the confirmed command path and the intents.
///
/// The in-app search stays the fast path for finding a device by name; this is for questions a ranked list does
/// not answer. Each question gets a fresh session, so answers don't depend on earlier ones.
@available(iOS 27.0, macOS 27.0, *)
final class DeviceAsk: Sendable {
    static let instructions = """
        You answer questions about the devices in one smart home. Each search result is one device: its title is \
        the room and the device name, and its description gives the device type, brand and room. Always search \
        before answering. Spotlight does not know whether a device is on, off, online or offline: when the \
        question is about that, add the deviceStatus stage after the search. Answer in one or two short sentences \
        and name the devices. You can only look things up; never say you changed a device.
        """

    /// False on devices without Apple Intelligence, or while the model is downloading.
    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This device doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in Settings to ask about your home."
        case .unavailable(.modelNotReady): "Apple Intelligence is still getting ready. Try again later."
        case .unavailable: "Apple Intelligence isn't available right now."
        }
    }

    init(services: AppSearchServices) {
        LiveStatusStage.install { await services.statuses(for: $0) }
    }

    func ask(_ question: String) async -> DeviceAnswer {
        let tool = Self.makeTool()
        let found = FoundDevices()
        let listener = Task {
            for await reply in tool.searchResults {
                let items: [CSSearchableItem] = switch reply.content {
                case .items(let items): items
                case .scoredItems(let scored): scored.sorted { $0.score > $1.score }.map(\.item)
                case .groupedItems(let groups): groups.values.flatMap { $0 }
                default: []
                }
                found.replace(with: items.compactMap { SpotlightItemMapping.deviceID(fromIdentifier: $0.uniqueIdentifier) })
            }
        }
        defer { listener.cancel() }
        let session = LanguageModelSession(model: .default, tools: [tool], instructions: Self.instructions)
        do {
            let response = try await session.respond(to: question)
            await Task.yield()  // let the last search reply reach the listener
            return DeviceAnswer(text: response.content, devices: found.devices)
        } catch let error as LanguageModelSession.GenerationError {
            return DeviceAnswer(text: "", devices: found.devices, failure: Self.message(for: error),
                                detail: String(describing: error))
        } catch {
            return DeviceAnswer(text: "", devices: found.devices, failure: "Couldn't answer that question right now.",
                                detail: String(describing: error))
        }
    }

    private static func makeTool() -> SpotlightSearchTool {
        var source = CoreSpotlightSource(fetchAttributes: [.displayName, .contentDescription, .containerTitle,
                                                           .keywords, .lastUsedDate])
        source.maximumResultCount = 50
        // Focused on plain items: the model searches titles and descriptions, and "used today" reads the last
        // used date the indexer keeps.
        let items = SpotlightSearchTool.ContentDomain.Items(title: [.displayName, .title],
                                                            text: [.contentDescription, .textContent, .keywords],
                                                            modified: [.lastUsedDate])
        return SpotlightSearchTool(configuration: .init(
            sources: [.coreSpotlight(source)],
            guide: .init(level: .focused(.items(items)), format: .compact),
            customStages: [LiveStatusStage(state: .on)]))
    }

    private static func message(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .guardrailViolation, .refusal: "That question can't be answered here."
        case .exceededContextWindowSize: "That question matched too much. Try naming a room or a device type."
        case .assetsUnavailable: "Apple Intelligence isn't available right now."
        case .rateLimited, .concurrentRequests: "Too many questions at once. Try again in a moment."
        case .unsupportedLanguageOrLocale: "Questions in this language aren't supported yet."
        default: "Couldn't answer that question."
        }
    }
}

/// The devices of the last search reply. The model may search more than once; its final search is the one its
/// answer is about.
private final class FoundDevices: Sendable {
    private let ids = Mutex<[DeviceID]>([])

    func replace(with devices: [DeviceID]) {
        var seen = Set<DeviceID>()
        let unique = devices.filter { seen.insert($0).inserted }
        ids.withLock { $0 = unique }
    }

    var devices: [DeviceID] { ids.withLock { $0 } }
}

/// A pipeline stage the model can add after a search: keeps the devices in a live state. Spotlight holds names,
/// rooms and types, but whether a light is on right now only the app knows.
@available(iOS 27.0, macOS 27.0, *)
@Generable(description: "Keeps only the devices that are currently in one state")
struct LiveStatusStage: CustomStage {
    @Generable
    enum State: String, Codable, Sendable {
        case online, offline, on, off
    }

    @Guide(description: "online or offline for connectivity; on or off for power")
    var state: State

    typealias Lookup = @Sendable ([DeviceID]) async -> [DeviceID: DeviceStatus]

    private static let lookup = Mutex<Lookup?>(nil)

    static func install(_ lookup: @escaping Lookup) {
        self.lookup.withLock { $0 = lookup }
    }

    static let name = "deviceStatus"
    static let description = """
        Keeps the devices that are online, offline, switched on or switched off right now. Use it after a search \
        whenever the question is about a device's current state.
        """
    static let inputTypes: [SearchPipelineDataType] = [.items, .scoredItems]
    static let outputTypes: [SearchPipelineDataType] = [.items, .scoredItems]

    nonisolated(nonsending) func execute(items: [CSSearchableItem]) async throws -> SearchPipelineData {
        let kept = await keptIdentifiers(items.map(\.uniqueIdentifier))
        return SearchPipelineData(payload: .items(items.filter { kept.contains($0.uniqueIdentifier) }))
    }

    nonisolated(nonsending) func execute(scoredItems: [ScoredSearchableItem]) async throws -> SearchPipelineData {
        let kept = await keptIdentifiers(scoredItems.map(\.item.uniqueIdentifier))
        return SearchPipelineData(payload: .scoredItems(scoredItems.filter { kept.contains($0.item.uniqueIdentifier) }))
    }

    /// Item identifiers whose device is in `state`. Devices without a reported status are dropped.
    private func keptIdentifiers(_ identifiers: [String]) async -> Set<String> {
        guard let lookup = Self.lookup.withLock({ $0 }) else { return [] }
        let devices = identifiers.compactMap { identifier in
            SpotlightItemMapping.deviceID(fromIdentifier: identifier).map { (identifier, $0) }
        }
        let statuses = await lookup(devices.map(\.1))
        return Set(devices.compactMap { identifier, device in
            guard let status = statuses[device], state.matches(status) else { return nil }
            return identifier
        })
    }
}

@available(iOS 27.0, macOS 27.0, *)
private extension LiveStatusStage.State {
    func matches(_ status: DeviceStatus) -> Bool {
        switch self {
        case .online: status.isOnline
        case .offline: !status.isOnline
        case .on: status.isOn == true
        case .off: status.isOn == false
        }
    }
}
#endif

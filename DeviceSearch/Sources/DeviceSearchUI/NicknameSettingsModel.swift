import Observation
import SearchCore
import DeviceSearch

/// Learned nicknames as the Settings screen needs them. `PersonalizationStore` conforms (one-line extension in
/// the app target), so the UI module does not depend on the personalization module.
public protocol NicknameManaging: Sendable {
    func learnedNicknames() async -> [DeviceID: [String]]
    func removeNickname(_ nickname: String, for device: DeviceID) async -> PersonalChange
}

/// "Learned names" in Settings (design doc §15 U06): lists every learned nickname and removes one on request.
/// A removed nickname is never learned again; the index rebuilds so it stops matching.
@MainActor
@Observable
public final class NicknameSettingsModel {
    public struct Item: Identifiable, Equatable, Sendable {
        public var device: DeviceID
        public var deviceName: String
        public var nickname: String
        public var id: String { device.rawValue + "|" + nickname }
    }

    public private(set) var items: [Item] = []

    @ObservationIgnored private let manager: any NicknameManaging
    @ObservationIgnored private let deviceNames: @Sendable ([DeviceID]) async -> [DeviceID: String]
    @ObservationIgnored private let onChange: @Sendable () async -> Void

    /// - Parameters:
    ///   - deviceNames: names for ids, for example from `SearchEngine.devices(withIDs:)`.
    ///   - onChange: called after a removal, for example `{ await home.sync.requestRebuild() }`.
    public init(manager: any NicknameManaging,
                deviceNames: @escaping @Sendable ([DeviceID]) async -> [DeviceID: String],
                onChange: @escaping @Sendable () async -> Void) {
        self.manager = manager
        self.deviceNames = deviceNames
        self.onChange = onChange
    }

    public func load() async {
        let learned = await manager.learnedNicknames()
        let names = await deviceNames(Array(learned.keys))
        items = learned.flatMap { device, nicknames in
            nicknames.map { Item(device: device, deviceName: names[device] ?? device.rawValue, nickname: $0) }
        }
        .sorted { ($0.deviceName, $0.nickname) < ($1.deviceName, $1.nickname) }
    }

    public func remove(_ item: Item) async {
        let change = await manager.removeNickname(item.nickname, for: item.device)
        items.removeAll { $0.id == item.id }
        if change.contains(.aliases) { await onChange() }
    }
}

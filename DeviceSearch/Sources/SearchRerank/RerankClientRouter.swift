import Synchronization
import SearchCore
import DeviceSearch

/// Who may rank (design doc §8 L11, §16 Z03). On-device is the only default. An off-device model is used
/// only after the person explicitly turns it on, and only while the on-device model is unavailable —
/// never as a silent fallback.
public enum ModelPreference: String, Sendable, Codable {
    case onDeviceOnly
    case allowOffDevice
}

public final class RerankClientRouter: RerankModelClient {
    public let onDevice: any RerankModelClient
    public let offDevice: (any RerankModelClient)?
    private let preference: Mutex<ModelPreference>

    public init(onDevice: any RerankModelClient, offDevice: (any RerankModelClient)? = nil,
                preference: ModelPreference = .onDeviceOnly) {
        self.onDevice = onDevice
        self.offDevice = offDevice
        self.preference = Mutex(preference)
    }

    /// Set from the person's choice in Settings.
    public func setPreference(_ value: ModelPreference) { preference.withLock { $0 = value } }

    public var currentPreference: ModelPreference { preference.withLock { $0 } }

    private func active() async -> (any RerankModelClient)? {
        if await onDevice.isAvailable() { return onDevice }
        guard currentPreference == .allowOffDevice, let offDevice, await offDevice.isAvailable() else { return nil }
        return offDevice
    }

    public func isAvailable() async -> Bool { await active() != nil }

    public func prewarm() async { await onDevice.prewarm() }

    public func rank(_ request: RerankModelRequest) async throws -> RerankAnswer {
        guard let client = await active() else { throw RefinementFailure(.unavailable) }
        return try await client.rank(request)
    }

    public func rankStreaming(_ request: RerankModelRequest,
                              onBest: @escaping @Sendable ([Int]) async -> Void) async throws -> RerankAnswer {
        guard let client = await active() else { throw RefinementFailure(.unavailable) }
        return try await client.rankStreaming(request, onBest: onBest)
    }

    public func contextSize() async -> Int { await (active() ?? onDevice).contextSize() }

    public func tokenCount(_ text: String) async -> Int? { await (active() ?? onDevice).tokenCount(text) }
}

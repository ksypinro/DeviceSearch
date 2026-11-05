import Foundation

/// Device state that disables the model (design doc §12, B03): Low Power Mode and serious thermal state.
public protocol DeviceConditions: Sendable {
    var isLowPowerModeEnabled: Bool { get }
    var isThermalStateSeriousOrWorse: Bool { get }
}

/// Reads `ProcessInfo` on Apple platforms. Elsewhere it reports normal conditions.
public struct SystemDeviceConditions: DeviceConditions {
    public init() {}

    public var isLowPowerModeEnabled: Bool {
        #if canImport(Darwin)
        return ProcessInfo.processInfo.isLowPowerModeEnabled
        #else
        return false
        #endif
    }

    public var isThermalStateSeriousOrWorse: Bool {
        #if canImport(Darwin)
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
        #else
        return false
        #endif
    }
}

/// Fixed conditions for tests.
public struct FixedDeviceConditions: DeviceConditions {
    public var isLowPowerModeEnabled: Bool
    public var isThermalStateSeriousOrWorse: Bool

    public init(lowPower: Bool = false, hot: Bool = false) {
        isLowPowerModeEnabled = lowPower
        isThermalStateSeriousOrWorse = hot
    }
}

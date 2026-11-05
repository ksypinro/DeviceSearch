import SearchCore

/// What the search screen hands to the app (MVVM-C, design doc §13 M03). The app's coordinator implements it.
@MainActor
public protocol SearchCoordinating: AnyObject {
    /// Open the device's screen. The app records usage there (`SearchEngine.recordUsage`) when the device is
    /// opened or controlled.
    func openDevice(_ id: DeviceID)
    /// Run a detected command ("turn off all lights") through the app's control intents (design doc §14 Y05).
    func perform(_ command: DetectedCommand)
}

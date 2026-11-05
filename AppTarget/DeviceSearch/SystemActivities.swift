import AppIntents
import CoreSpotlight
import SwiftUI
import SearchCore

/// How the system hands people back to the app, and what the app tells the system in return (design doc §14):
/// Spotlight results, "Search in App", the device screen as an `NSUserActivity`, and intent donations.
enum SystemActivities {
    /// Listed under `NSUserActivityTypes` in Info.plist as `$(PRODUCT_BUNDLE_IDENTIFIER).viewDevice`.
    static let viewDeviceType = (Bundle.main.bundleIdentifier ?? "app") + ".viewDevice"
    static let deviceKey = "deviceID"
}

extension View {
    /// Opens what the system hands back: a tapped Spotlight result (`CSSearchableItemActionType`), "Search in
    /// App" from Spotlight (`CSQueryContinuationActionType`, needs `CoreSpotlightContinuation` in Info.plist), and
    /// a device screen continued from a suggestion. `OpenDeviceIntent` covers Siri and Shortcuts.
    func routesSystemActivities(to router: AppRouter) -> some View {
        onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let device = SpotlightItemMapping.deviceID(fromIdentifier: identifier) else { return }
            router.openDevice(id: device.rawValue)
        }
        .onContinueUserActivity(CSQueryContinuationActionType) { activity in
            guard let term = activity.userInfo?[CSSearchQueryString] as? String, !term.isEmpty else { return }
            router.showSearch(term)
        }
        .onContinueUserActivity(SystemActivities.viewDeviceType) { activity in
            guard let id = activity.userInfo?[SystemActivities.deviceKey] as? String else { return }
            router.openDevice(id: id)
        }
    }

    /// Publishes the device on screen as the current activity: Siri knows what "turn this off" means, and the
    /// system can suggest returning to it. It is linked to the device's Spotlight item, so search shows one
    /// result. Locks, cameras, doorbells and garage doors are not offered to search or suggestions.
    func deviceActivity(_ device: DeviceEntity?) -> some View {
        userActivity(SystemActivities.viewDeviceType, isActive: device != nil) { activity in
            guard let device else { return }
            let sensitive = SpotlightItemMapping.sensitiveTypes.contains(device.typeID)
            activity.title = SpotlightItemMapping.displayName(name: device.name, room: device.room)
            activity.userInfo = [SystemActivities.deviceKey: device.id]
            activity.requiredUserInfoKeys = [SystemActivities.deviceKey]
            activity.targetContentIdentifier = device.id
            activity.appEntityIdentifier = EntityIdentifier(for: device)
            activity.isEligibleForSearch = !sensitive
            activity.isEligibleForPrediction = !sensitive
            let attributes = device.attributeSet
            attributes.relatedUniqueIdentifier = SpotlightItemMapping.identifier(for: DeviceID(device.id))
            activity.contentAttributeSet = attributes
        }
    }
}

/// Tells the system a device was switched in the app, so Siri and Spotlight learn the habit and suggest the
/// matching shortcut ("Turn off Bedroom AC" at bedtime). Call it from your control code after a change
/// succeeds; devices the power intents refuse (locks, cameras, …) are not donated.
enum DeviceIntentDonation {
    static func power(_ on: Bool, device: DeviceEntity) {
        guard !SpotlightItemMapping.sensitiveTypes.contains(device.typeID) else { return }
        if on {
            let intent = TurnOnDeviceIntent()
            intent.device = device
            _ = intent.donate()
        } else {
            let intent = TurnOffDeviceIntent()
            intent.device = device
            _ = intent.donate()
        }
    }
}

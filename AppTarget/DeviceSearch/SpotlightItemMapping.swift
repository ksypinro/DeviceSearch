import AppIntents
@preconcurrency import CoreSpotlight
import Foundation
import Synchronization
import UniformTypeIdentifiers
import SearchCore
import SearchIndex
#if canImport(UIKit)
import UIKit
#endif

/// How a device appears in system Spotlight (design doc §14 Y04). System Spotlight matches mainly `displayName`
/// and `title` (from iOS 17 it ignores `keywords`), so both carry the words people type: room and name.
enum SpotlightItemMapping {
    /// Bump when the attributes change: the next launch deletes and re-indexes every device.
    static let schemaVersion = 2
    /// Items expire unless donated again; the indexer re-donates everything well before this.
    static let lifetime: TimeInterval = 60 * 60 * 24 * 365
    /// Types whose results go in the index that is unreadable while the device is locked.
    static let sensitiveTypes: Set<String> = ["lock", "camera", "doorbell", "garage"]

    static let typeKey = CSCustomAttributeKey(keyName: "deviceType")!
    static let manufacturerKey = CSCustomAttributeKey(keyName: "manufacturer")!

    private static let idPrefix = "device."

    static func identifier(for device: DeviceID) -> String { idPrefix + device.rawValue }

    static func deviceID(fromIdentifier identifier: String) -> DeviceID? {
        guard identifier.hasPrefix(idPrefix) else { return nil }
        return DeviceID(String(identifier.dropFirst(idPrefix.count)))
    }

    /// One domain per home, so leaving a home is one delete.
    static func domain(for home: HomeID) -> String { "home.\(home.rawValue)" }

    static func isSensitive(_ document: SearchDocument) -> Bool { sensitiveTypes.contains(document.typeID) }

    /// What the indexer compares to decide whether a device needs donating again. Live state and usage counts
    /// stay out: they change too often for the system index.
    static func signature(of document: SearchDocument) -> String {
        [document.contentHash, document.aliasTokens.joined(separator: ","),
         document.device.usage?.isFavorite == true ? "favorite" : ""].joined(separator: "|")
    }

    /// "Bedroom AC" for an "AC" in the Bedroom; a name that already mentions its room stays as it is.
    static func displayName(name: String, room: String?) -> String {
        guard let room, !room.isEmpty,
              name.range(of: room, options: [.caseInsensitive, .diacriticInsensitive]) == nil else { return name }
        return "\(room) \(name)"
    }

    /// The attributes shared by the indexed item and `DeviceEntity.attributeSet`.
    static func attributeSet(name: String, type: String, manufacturer: String, room: String?,
                             keywords: [String]) -> CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        let title = displayName(name: name, room: room)
        attributes.title = title
        attributes.displayName = title
        attributes.contentDescription = [type, manufacturer, room ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        attributes.keywords = keywords
        attributes.containerTitle = room
        attributes.setValue(type as NSString, forCustomKey: typeKey)
        attributes.setValue(manufacturer as NSString, forCustomKey: manufacturerKey)
        return attributes
    }

    static func item(for document: SearchDocument, homeID: HomeID, lastUsed: Date?) -> CSSearchableItem {
        let device = document.device
        let entity = DeviceEntity(document: document)
        let attributes = attributeSet(name: device.name, type: document.typeCard.label,
                                      manufacturer: device.manufacturer, room: device.room, keywords: entity.keywords)
        // "Bedroom AC. Air Conditioner (ac, aircon, cooler). Samsung. In Bedroom." for semantic matching.
        attributes.textContent = document.embeddingText
        attributes.containerIdentifier = document.roomID.map { "room.\($0)" }
        attributes.thumbnailData = thumbnail(forType: document.typeID)
        attributes.lastUsedDate = [device.usage?.lastUsedAt, lastUsed].compactMap { $0 }.max()
        let favorite = device.usage?.isFavorite == true
        attributes.rankingHint = NSNumber(value: favorite ? 10 : 1)

        let item = CSSearchableItem(uniqueIdentifier: identifier(for: device.id), domainIdentifier: domain(for: homeID),
                                    attributeSet: attributes)
        item.expirationDate = Date().addingTimeInterval(lifetime)
        item.associateAppEntity(entity, priority: favorite ? 10 : 1)
        return item
    }

    /// Moves an indexed device's last-used date forward without re-sending the rest of the item.
    static func usagePatch(for device: DeviceID, homeID: HomeID, date: Date) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.lastUsedDate = date
        let patch = CSSearchableItem(uniqueIdentifier: identifier(for: device), domainIdentifier: domain(for: homeID),
                                     attributeSet: attributes)
        patch.expirationDate = Date().addingTimeInterval(lifetime)
        patch.isUpdate = true
        return patch
    }

    // MARK: Icons

    static func symbol(forType typeID: String) -> String { symbols[typeID] ?? "house.fill" }

    private static let symbols: [String: String] = [
        "ac": "air.conditioner.horizontal.fill", "tv": "tv.fill", "light": "lightbulb.fill", "fan": "fan.fill",
        "plug": "powerplug.fill", "switch": "lightswitch.on.fill", "thermostat": "thermometer.medium",
        "camera": "video.fill", "lock": "lock.fill", "doorbell": "video.doorbell.fill", "speaker": "hifispeaker.fill",
        "vacuum": "robotic.vacuum.fill", "fridge": "refrigerator.fill", "washer": "washer.fill",
        "purifier": "air.purifier.fill", "motion": "figure.walk.motion", "contact": "door.left.hand.closed",
        "tempsensor": "thermometer.medium", "leak": "drop.fill", "smoke": "smoke.fill",
        "blinds": "blinds.horizontal.closed", "garage": "door.garage.closed", "geyser": "spigot.fill",
        "heater": "heater.vertical.fill", "humidifier": "humidifier.fill", "hub": "homepod.fill",
        "router": "wifi.router.fill", "oven": "oven.fill", "dishwasher": "dishwasher.fill",
        "projector": "videoprojector.fill", "sprinkler": "sprinkler.and.droplets.fill", "evcharger": "ev.charger.fill",
        "media": "play.tv.fill",
    ]

    private static let thumbnails = Mutex<[String: Data]>([:])

    /// A white type glyph on a blue rounded square, readable in light and dark mode. Rendered once per type.
    static func thumbnail(forType typeID: String) -> Data? {
        #if canImport(UIKit)
        if let cached = thumbnails.withLock({ $0[typeID] }) { return cached }
        let configuration = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        guard let glyph = UIImage(systemName: symbol(forType: typeID), withConfiguration: configuration)?
            .withTintColor(.white, renderingMode: .alwaysOriginal) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: 60, height: 60)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let data = UIGraphicsImageRenderer(bounds: bounds, format: format).pngData { _ in
            UIColor(red: 0, green: 0.48, blue: 1, alpha: 1).setFill()
            UIBezierPath(roundedRect: bounds, cornerRadius: 13.5).fill()
            glyph.draw(at: CGPoint(x: (bounds.width - glyph.size.width) / 2, y: (bounds.height - glyph.size.height) / 2))
        }
        thumbnails.withLock { $0[typeID] = data }
        return data
        #else
        return nil
        #endif
    }
}

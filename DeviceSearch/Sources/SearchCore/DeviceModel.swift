import Foundation

/// Stable identifier of a device. Wraps the app's own device ID string.
public struct DeviceID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public var description: String { rawValue }
    public static func < (lhs: DeviceID, rhs: DeviceID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Identifier of a home. Indexes and personalization are scoped per home.
public struct HomeID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public var description: String { rawValue }
    public static func < (lhs: HomeID, rhs: HomeID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Device type identifier. Must match an `id` in the knowledge base's types.json (for example "ac", "tv", "light").
/// Unknown values are treated as the knowledge base's "other" type.
public struct DeviceTypeID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public var description: String { rawValue }
    public static func < (lhs: DeviceTypeID, rhs: DeviceTypeID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Live state of a device. Optional on `DeviceRecord`: a missing status means "no signal", never "offline".
public struct DeviceStatus: Hashable, Sendable, Codable {
    /// Whether the device is reachable.
    public var isOnline: Bool
    /// Power state, or nil for devices without one (sensors, locks).
    public var isOn: Bool?

    public init(isOnline: Bool, isOn: Bool? = nil) {
        self.isOnline = isOnline
        self.isOn = isOn
    }
}

/// Usage information the app already tracks. Personalization (milestone 4) can replace it with decayed counts.
public struct UsageStats: Hashable, Sendable, Codable {
    public var useCount: Int
    public var isFavorite: Bool
    public var lastUsedAt: Date?

    public init(useCount: Int = 0, isFavorite: Bool = false, lastUsedAt: Date? = nil) {
        self.useCount = useCount
        self.isFavorite = isFavorite
        self.lastUsedAt = lastUsedAt
    }
}

/// The searchable view of one device. The app maps its own device model into this type.
public struct DeviceRecord: Hashable, Sendable, Codable, Identifiable {
    public let id: DeviceID
    public var name: String
    public var manufacturer: String
    public var type: DeviceTypeID
    public var room: String?
    public var status: DeviceStatus?
    public var usage: UsageStats?

    public init(
        id: DeviceID,
        name: String,
        manufacturer: String,
        type: DeviceTypeID,
        room: String? = nil,
        status: DeviceStatus? = nil,
        usage: UsageStats? = nil
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.type = type
        self.room = room
        self.status = status
        self.usage = usage
    }

    /// Hash of the searchable text fields (name, manufacturer, type, room).
    /// Status and usage are excluded: they change often and never require re-embedding.
    public var contentHash: String {
        StableHash.hex([name, manufacturer, type.rawValue, room ?? ""].joined(separator: "\u{1F}"))
    }
}

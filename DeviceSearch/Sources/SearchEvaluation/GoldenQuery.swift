import Foundation
import SearchCore

/// Golden-set categories (design doc §17).
public enum GoldenCategory: String, Codable, Sendable, CaseIterable {
    case navigational, typo, set, compound, descriptive, number, multilingual
}

/// What a correct answer looks like.
public enum GoldenExpectation: Codable, Sendable, Equatable {
    /// One specific device must come first (navigational, typo, number).
    case device(DeviceID)
    /// Exactly this set of devices (set and compound queries).
    case set([DeviceID])
    /// Graded relevance for descriptive queries: device → gain (2 = clearly right, 1 = acceptable).
    case graded([DeviceID: Int])
}

public struct GoldenQuery: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    public var category: GoldenCategory
    public var expectation: GoldenExpectation

    public init(id: String, text: String, category: GoldenCategory, expectation: GoldenExpectation) {
        self.id = id
        self.text = text
        self.category = category
        self.expectation = expectation
    }
}

/// A handwritten descriptive or multilingual query, resolved against a home by `GoldenSetBuilder`.
/// Devices whose type is in `primary` get gain 2 (1 outside the requested room); `secondary` types get gain 1.
public struct HandwrittenQuery: Codable, Sendable, Equatable {
    public var text: String
    public var category: GoldenCategory
    public var primary: [String]
    public var secondary: [String]
    /// Optional room id ("bedroom"). Devices in other rooms get lower gains; for set expectations it filters.
    public var room: String?
    /// "graded" (descriptive), "set" (multilingual set queries) or "device:<exact name>".
    public var expect: String

    public init(text: String, category: GoldenCategory, primary: [String], secondary: [String] = [],
                room: String? = nil, expect: String = "graded") {
        self.text = text
        self.category = category
        self.primary = primary
        self.secondary = secondary
        self.room = room
        self.expect = expect
    }
}

/// A fixed-capacity set of document ordinals backed by 64-bit words.
/// Used for facet filters (type, brand, room, online, power): AND, OR and AND-NOT over 500 devices take nanoseconds.
public struct Bitset: Hashable, Sendable {
    /// Number of addressable bits (the document count).
    public let capacity: Int
    public private(set) var words: [UInt64]

    /// An empty set that can hold ordinals `0..<capacity`.
    public init(capacity: Int) {
        precondition(capacity >= 0, "capacity must not be negative")
        self.capacity = capacity
        self.words = Array(repeating: 0, count: (capacity + 63) / 64)
    }

    /// A set containing every ordinal in `0..<capacity`.
    public static func full(capacity: Int) -> Bitset {
        var set = Bitset(capacity: capacity)
        for index in 0..<capacity { set.insert(index) }
        return set
    }

    /// A set containing the given ordinals.
    public init<S: Sequence>(capacity: Int, members: S) where S.Element == Int {
        self.init(capacity: capacity)
        for member in members { insert(member) }
    }

    public mutating func insert(_ ordinal: Int) {
        precondition(ordinal >= 0 && ordinal < capacity, "ordinal \(ordinal) out of range 0..<\(capacity)")
        words[ordinal >> 6] |= (1 << UInt64(ordinal & 63))
    }

    public mutating func remove(_ ordinal: Int) {
        precondition(ordinal >= 0 && ordinal < capacity, "ordinal \(ordinal) out of range 0..<\(capacity)")
        words[ordinal >> 6] &= ~(1 << UInt64(ordinal & 63))
    }

    public func contains(_ ordinal: Int) -> Bool {
        guard ordinal >= 0 && ordinal < capacity else { return false }
        return words[ordinal >> 6] & (1 << UInt64(ordinal & 63)) != 0
    }

    public func union(_ other: Bitset) -> Bitset {
        precondition(capacity == other.capacity, "capacities differ")
        var result = self
        for index in result.words.indices { result.words[index] |= other.words[index] }
        return result
    }

    public func intersection(_ other: Bitset) -> Bitset {
        precondition(capacity == other.capacity, "capacities differ")
        var result = self
        for index in result.words.indices { result.words[index] &= other.words[index] }
        return result
    }

    /// Members of `self` that are not in `other` (AND-NOT).
    public func subtracting(_ other: Bitset) -> Bitset {
        precondition(capacity == other.capacity, "capacities differ")
        var result = self
        for index in result.words.indices { result.words[index] &= ~other.words[index] }
        return result
    }

    public var isEmpty: Bool { words.allSatisfy { $0 == 0 } }

    /// Number of members.
    public var count: Int { words.reduce(0) { $0 + $1.nonzeroBitCount } }

    /// Members in ascending order.
    public var members: [Int] {
        var result: [Int] = []
        result.reserveCapacity(count)
        for (wordIndex, word) in words.enumerated() {
            var remaining = word
            while remaining != 0 {
                let bit = remaining.trailingZeroBitCount
                result.append(wordIndex * 64 + bit)
                remaining &= remaining - 1
            }
        }
        return result
    }
}

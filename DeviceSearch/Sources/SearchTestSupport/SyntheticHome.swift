import Foundation
import SearchCore
import SearchText

/// The mulberry32 generator used by the design-doc lab. Same seed → same sequence on every platform.
public struct Mulberry32: Sendable {
    private var state: UInt32

    public init(seed: UInt32) { state = seed }

    /// Next value in [0, 1).
    public mutating func next() -> Double {
        state = state &+ 0x6D2B_79F5
        var t = (state ^ (state >> 15)) &* (1 | state)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }
}

/// Synthetic homes for tests and evaluation (design doc §17): 48 hand-written devices followed by seeded
/// random devices spread over 26 rooms. `SyntheticHome.make(count: 500, seed: 7)` reproduces the lab's home.
public enum SyntheticHome {
    /// The 48 hand-written devices ("Bedroom AC", "TV 2", "TV 12", "Bob's Lamp", …).
    public static var curated: [DeviceRecord] { make(count: SyntheticTables.curated.count) }

    public static func make(count: Int, seed: UInt32 = 7) -> [DeviceRecord] {
        var random = Mulberry32(seed: seed)
        let normalizer = TextNormalizer()
        var devices: [DeviceRecord] = []
        var used: [String: Int] = [:]

        func add(_ name: String, _ type: String, _ brand: String, _ room: String,
                 uses: Int?, favorite: Bool, online: Bool?) {
            let isOnline = online ?? (random.next() < 0.94)
            let isOn: Bool? = SyntheticTables.powered.contains(type) ? random.next() < 0.35 : nil
            let useCount = uses ?? Int((pow(random.next(), 3) * 30).rounded(.down))
            let id = DeviceID(String(format: "d%03d", devices.count + 1))
            devices.append(DeviceRecord(
                id: id, name: name, manufacturer: brand, type: DeviceTypeID(type), room: room,
                status: DeviceStatus(isOnline: isOnline, isOn: isOn),
                usage: UsageStats(useCount: useCount, isFavorite: favorite)))
        }

        for (name, type, brand, room, uses, favorite, online) in SyntheticTables.curated {
            if devices.count >= count { break }
            add(name, type, brand, room, uses: uses, favorite: favorite, online: online)
            used[normalizer.normalize(name)] = 1
        }

        func pick<T>(_ items: [T]) -> T { items[Int((random.next() * Double(items.count)).rounded(.down))] }
        let totalWeight = SyntheticTables.rooms.reduce(0) { $0 + $1.2 }
        func pickRoom() -> (String, String, Int) {
            var x = random.next() * Double(totalWeight)
            for room in SyntheticTables.rooms {
                x -= Double(room.2)
                if x <= 0 { return room }
            }
            return SyntheticTables.rooms[SyntheticTables.rooms.count - 1]
        }

        var guardCount = 0
        while devices.count < count && guardCount < count * 30 {
            guardCount += 1
            let room = pickRoom()
            let typeID = random.next() < 0.55
                ? pick(SyntheticTables.genericFill)
                : pick(SyntheticTables.roomTypes[room.0] ?? SyntheticTables.genericFill)
            let table = SyntheticTables.types[typeID]!
            let variant = pick(table.names)
            let brandIndex = min(table.brands.count - 1, Int((pow(random.next(), 1.6) * Double(table.brands.count)).rounded(.down)))
            let brand = table.brands[brandIndex]
            let base = random.next() < 0.12
                ? "\(SyntheticTables.brandShortNames[brand] ?? brand) \(variant)"
                : "\(room.1) \(variant)"
            let key = normalizer.normalize(base)
            let k = (used[key] ?? 0) + 1
            if !SyntheticTables.manyAllowed.contains(typeID) && k > 2 { continue }
            used[key] = k
            add(k == 1 ? base : "\(base) \(k)", typeID, brand, room.0, uses: nil, favorite: false, online: nil)
        }
        return devices
    }
}

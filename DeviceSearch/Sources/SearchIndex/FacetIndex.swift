import SearchCore

/// Facet bitsets over document ordinals (design doc §6): type, brand, room and live state.
/// Devices without a status are in neither the online nor the offline set ("no signal").
public struct FacetIndex: Sendable {
    public let capacity: Int
    public let all: Bitset
    public let types: [String: Bitset]
    public let brands: [String: Bitset]
    public let rooms: [String: Bitset]
    /// Room id → stemmed tokens of the room name, for partial room matches.
    public let roomTokens: [String: [String]]
    public private(set) var online: Bitset
    public private(set) var offline: Bitset
    public private(set) var poweredOn: Bitset
    public private(set) var poweredOff: Bitset

    public init(documents: [SearchDocument]) {
        let capacity = documents.count
        var types: [String: Bitset] = [:]
        var brands: [String: Bitset] = [:]
        var rooms: [String: Bitset] = [:]
        var roomTokens: [String: [String]] = [:]
        for document in documents {
            types[document.typeID, default: Bitset(capacity: capacity)].insert(document.ordinal)
            brands[document.brandID, default: Bitset(capacity: capacity)].insert(document.ordinal)
            if let room = document.room {
                rooms[room.id, default: Bitset(capacity: capacity)].insert(document.ordinal)
                roomTokens[room.id] = roomTokens[room.id] ?? room.tokens
            }
        }
        self.capacity = capacity
        self.all = Bitset.full(capacity: capacity)
        self.types = types
        self.brands = brands
        self.rooms = rooms
        self.roomTokens = roomTokens
        self.online = Bitset(capacity: capacity)
        self.offline = Bitset(capacity: capacity)
        self.poweredOn = Bitset(capacity: capacity)
        self.poweredOff = Bitset(capacity: capacity)
        for document in documents { setStatus(document.device.status, at: document.ordinal) }
    }

    /// Updates the live-state bitsets for one document (status fast path, design doc §11).
    public mutating func setStatus(_ status: DeviceStatus?, at ordinal: Int) {
        online.remove(ordinal); offline.remove(ordinal); poweredOn.remove(ordinal); poweredOff.remove(ordinal)
        guard let status else { return }
        if status.isOnline { online.insert(ordinal) } else { offline.insert(ordinal) }
        switch status.isOn {
        case true?: poweredOn.insert(ordinal)
        case false?: poweredOff.insert(ordinal)
        case nil: break
        }
    }

    public func members(_ condition: StatusCondition) -> Bitset {
        switch condition {
        case .online: return online
        case .offline: return offline
        case .on: return poweredOn
        case .off: return poweredOff
        }
    }

    /// Devices matching one entity. Rooms match exactly when that room exists in the home; otherwise every
    /// room whose name contains all of the entity's words ("bedroom" → "Master Bedroom", "Bedroom 2").
    public func members(of entity: QueryEntity) -> Bitset {
        let empty = Bitset(capacity: capacity)
        switch entity.kind {
        case .type: return types[entity.id] ?? empty
        case .brand: return brands[entity.id] ?? empty
        case .status: return entity.statusCondition.map(members) ?? empty
        case .room:
            if let exact = rooms[entity.id], !exact.isEmpty { return exact }
            guard !entity.roomTokens.isEmpty else { return empty }
            var result = empty
            for (id, tokens) in roomTokens where entity.roomTokens.allSatisfy(tokens.contains) {
                if let members = rooms[id] { result = result.union(members) }
            }
            return result
        }
    }

    /// OR within a kind (two brands), AND across kinds, AND-NOT for exclusions (design doc §6).
    public func members(types: [QueryEntity], brands: [QueryEntity], rooms: [QueryEntity],
                        network: StatusCondition?, power: StatusCondition?, excluded: [QueryEntity]) -> Bitset {
        var result = all
        for group in [types, brands, rooms] where !group.isEmpty {
            var union = Bitset(capacity: capacity)
            for entity in group { union = union.union(members(of: entity)) }
            result = result.intersection(union)
        }
        if let network { result = result.intersection(members(network)) }
        if let power { result = result.intersection(members(power)) }
        for entity in excluded { result = result.subtracting(members(of: entity)) }
        return result
    }
}

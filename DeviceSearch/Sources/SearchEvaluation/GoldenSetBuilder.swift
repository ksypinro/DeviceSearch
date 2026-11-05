import Foundation
import SearchCore
import SearchIndex
import SearchTestSupport

/// Builds the golden set for a home (design doc §17). Navigational, typo, number, set and compound queries are
/// generated from the home's own devices, so their expected answers are correct by construction; descriptive
/// and multilingual queries come from the handwritten JSON files in this module's resources.
public struct GoldenSetBuilder {
    public struct Counts: Sendable {
        public var navigational = 60
        public var typo = 120
        public var set = 60
        public var compound = 40
        public var number = 20

        public init() {}

        /// Category sizes from the design doc (with 60 descriptive and 20 multilingual handwritten queries: 380).
        public static let designDoc = Counts()
    }

    public let snapshot: IndexSnapshot

    public init(snapshot: IndexSnapshot) {
        self.snapshot = snapshot
    }

    public func build(counts: Counts = .designDoc, seed: UInt32 = 3,
                      handwritten: [HandwrittenQuery] = GoldenSetBuilder.bundledHandwritten()) -> [GoldenQuery] {
        var random = Mulberry32(seed: seed)
        let documents = shuffled(snapshot.documents, &random)
        let uniqueNames = Dictionary(grouping: snapshot.documents, by: { snapshot.pipeline.key($0.device.name) })
            .filter { $0.value.count == 1 }
        let namedOnce = documents.filter { uniqueNames[snapshot.pipeline.key($0.device.name)] != nil }

        var queries: [GoldenQuery] = []
        // Navigational: names as typed, lowercase.
        for (index, document) in namedOnce.prefix(counts.navigational).enumerated() {
            queries.append(GoldenQuery(id: "nav-\(index)", text: document.device.name.lowercased(),
                                       category: .navigational, expectation: .device(document.id)))
        }
        // Typos: one perturbation per name; skip typos that spell another device's name.
        var perturber = TypoPerturber(seed: seed &+ 1)
        var typoCount = 0
        for document in namedOnce where typoCount < counts.typo {
            guard let typo = perturber.perturb(document.device.name),
                  uniqueNames[snapshot.pipeline.key(typo)] == nil else { continue }
            queries.append(GoldenQuery(id: "typo-\(typoCount)", text: typo, category: .typo,
                                       expectation: .device(document.id)))
            typoCount += 1
        }
        // Numbers: names ending in a number ("TV 2", "Kitchen Light 3").
        let numbered = namedOnce.filter { $0.device.name.split(separator: " ").last?.allSatisfy(\.isNumber) == true }
        for (index, document) in numbered.prefix(counts.number).enumerated() {
            queries.append(GoldenQuery(id: "num-\(index)", text: document.device.name.lowercased(), category: .number,
                                       expectation: .device(document.id)))
        }
        queries += setQueries(limit: counts.set)
        queries += compoundQueries(limit: counts.compound)
        queries += resolve(handwritten)
        return queries
    }

    // MARK: Set and compound queries

    func setQueries(limit: Int) -> [GoldenQuery] {
        var result: [GoldenQuery] = []
        func add(_ text: String, _ members: [SearchDocument]) {
            guard result.count < limit, members.count >= 2 else { return }
            result.append(GoldenQuery(id: "set-\(result.count)", text: text, category: .set,
                                      expectation: .set(members.map(\.id))))
        }
        let byType = Dictionary(grouping: snapshot.documents, by: \.typeID)
        let byRoom = Dictionary(grouping: snapshot.documents, by: { $0.roomID ?? "" })
        let byBrand = Dictionary(grouping: snapshot.documents.filter(\.brand.isKnown), by: \.brandID)
        for typeID in byType.keys.sorted() where typeID != "other" {
            let label = byType[typeID]![0].typeCard.label
            add(Self.plural(label), byType[typeID]!)
            add("all " + Self.plural(label), byType[typeID]!)
        }
        for roomID in byRoom.keys.sorted() where !roomID.isEmpty {
            add("everything in the " + byRoom[roomID]![0].room!.name.lowercased(), byRoom[roomID]!)
        }
        for brandID in byBrand.keys.sorted() {
            add(byBrand[brandID]![0].brand.name.lowercased() + " devices", byBrand[brandID]!)
        }
        add("offline devices", snapshot.documents.filter { $0.device.status?.isOnline == false })
        return result
    }

    func compoundQueries(limit: Int) -> [GoldenQuery] {
        var result: [GoldenQuery] = []
        func add(_ text: String, _ members: [SearchDocument]) {
            guard result.count < limit, !members.isEmpty, !result.contains(where: { $0.text == text }) else { return }
            result.append(GoldenQuery(id: "cmp-\(result.count)", text: text, category: .compound,
                                      expectation: .set(members.map(\.id))))
        }
        let types = ["light", "ac", "camera", "plug", "tv", "fan", "switch", "speaker", "blinds", "motion"]
        let rooms = ["bedroom", "kitchen", "living-room", "garage", "guest-room", "hallway", "home-office", "garden"]
        // Round-robin over patterns so every kind of compound query is represented.
        for round in 0..<3 {
            for (index, typeID) in types.enumerated() {
                guard let card = snapshot.knowledge.typeCard(id: typeID) else { continue }
                let plural = Self.plural(card.label)
                let ofType = snapshot.documents.filter { $0.typeID == typeID }
                let room = rooms[(index + round * 3) % rooms.count]
                guard let roomName = snapshot.knowledge.rooms.first(where: { $0.id == room })?.name.lowercased() else { continue }
                switch round {
                case 0:
                    add("\(plural) in the \(roomName)", ofType.filter { $0.roomID == room })
                    add("\(plural) except \(roomName)", ofType.filter { $0.roomID != room })
                case 1:
                    add("offline \(plural)", ofType.filter { $0.device.status?.isOnline == false })
                    if let brand = ofType.first?.brand, brand.isKnown {
                        add("\(brand.name.lowercased()) \(plural)", ofType.filter { $0.brandID == brand.id })
                    }
                default:
                    add("\(plural) in the \(roomName)", ofType.filter { $0.roomID == room })
                    if card.powered {
                        add("\(plural) that are on", ofType.filter { $0.device.status?.isOn == true })
                    }
                }
            }
        }
        return result
    }

    // MARK: Handwritten queries

    func resolve(_ handwritten: [HandwrittenQuery]) -> [GoldenQuery] {
        handwritten.enumerated().compactMap { index, item in
            let id = "\(item.category.rawValue)-\(index)"
            if item.expect.hasPrefix("device:") {
                let name = String(item.expect.dropFirst("device:".count))
                guard let document = snapshot.documents.first(where: { $0.device.name == name }) else { return nil }
                return GoldenQuery(id: id, text: item.text, category: item.category, expectation: .device(document.id))
            }
            if item.expect == "set" {
                // An empty primary list means any type ("রান্নাঘর" = everything in the kitchen).
                let members = snapshot.documents.filter { document in
                    (item.primary.isEmpty || item.primary.contains(document.typeID))
                        && (item.room == nil || document.roomID == item.room)
                }
                guard !members.isEmpty else { return nil }
                return GoldenQuery(id: id, text: item.text, category: item.category, expectation: .set(members.map(\.id)))
            }
            var gains: [DeviceID: Int] = [:]
            for document in snapshot.documents {
                let roomStrength = item.room.map { document.roomMatch(id: $0, tokens: [$0]) } ?? 1
                if item.primary.contains(document.typeID) {
                    let gain = roomStrength == 1 ? 2 : (roomStrength > 0 ? 1 : 0)
                    if gain > 0 { gains[document.id] = gain }
                } else if item.secondary.contains(document.typeID), roomStrength == 1 {
                    gains[document.id] = 1
                }
            }
            guard !gains.isEmpty else { return nil }
            return GoldenQuery(id: id, text: item.text, category: item.category, expectation: .graded(gains))
        }
    }

    /// golden-descriptive.json and golden-multilingual.json from this module's resources.
    public static func bundledHandwritten() -> [HandwrittenQuery] {
        ["golden-descriptive", "golden-multilingual"].flatMap { name -> [HandwrittenQuery] in
            guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let items = try? JSONDecoder().decode([HandwrittenQuery].self, from: data) else { return [] }
            return items
        }
    }

    // MARK: Helpers

    static func plural(_ label: String) -> String {
        let lower = label.lowercased()
        if lower.hasSuffix("s") { return lower }
        if lower.hasSuffix("ch") || lower.hasSuffix("sh") || lower.hasSuffix("x") { return lower + "es" }
        return lower + "s"
    }

    func shuffled<T>(_ items: [T], _ random: inout Mulberry32) -> [T] {
        var result = items
        guard result.count > 1 else { return result }
        for index in stride(from: result.count - 1, to: 0, by: -1) {
            let other = Int(random.next() * Double(index + 1))
            result.swapAt(index, other)
        }
        return result
    }
}

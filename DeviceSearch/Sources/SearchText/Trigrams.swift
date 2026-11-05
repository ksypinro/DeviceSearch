/// Character trigrams for fuzzy name matching (design doc §6).
public enum Trigrams {
    /// Trigrams of `key` padded with `$` on both sides: "tv" → ["$tv", "tv$"].
    public static func of(_ key: String) -> Set<String> {
        if key.utf8.allSatisfy({ $0 < 0x80 && $0 != 0x0D }) {
            var bytes: [UInt8] = [0x24]
            bytes.append(contentsOf: key.utf8)
            bytes.append(0x24)
            guard bytes.count >= 3 else { return [] }
            var grams = Set<String>(minimumCapacity: bytes.count)
            for start in 0...(bytes.count - 3) {
                grams.insert(String(decoding: bytes[start..<(start + 3)], as: UTF8.self))
            }
            return grams
        }
        let padded = Array("$" + key + "$")
        guard padded.count >= 3 else { return [] }
        var grams = Set<String>()
        for start in 0...(padded.count - 3) {
            grams.insert(String(padded[start..<(start + 3)]))
        }
        return grams
    }

    /// Dice coefficient 2|A∩B| / (|A| + |B|).
    public static func dice(shared: Int, _ sizeA: Int, _ sizeB: Int) -> Double {
        guard sizeA + sizeB > 0 else { return 0 }
        return 2 * Double(shared) / Double(sizeA + sizeB)
    }

    public static func dice(_ a: Set<String>, _ b: Set<String>) -> Double {
        dice(shared: a.intersection(b).count, a.count, b.count)
    }
}

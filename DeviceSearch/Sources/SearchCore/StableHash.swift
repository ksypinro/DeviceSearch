/// Deterministic 64-bit FNV-1a hash.
/// Swift's `Hasher` is randomly seeded per process, so it cannot be used for values stored on disk
/// (embedding cache keys, content hashes). This one returns the same value on every launch and platform.
public enum StableHash {
    public static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// The hash as a 16-character lowercase hex string.
    public static func hex(_ text: String) -> String {
        let value = fnv1a64(text)
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}

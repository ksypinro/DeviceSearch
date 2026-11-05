import SearchCore
import SearchIndex

/// A rough, deterministic estimate of an index snapshot's heap size (design doc §12, B02: under 1.5 MB at
/// 500 devices, excluding the language model). It counts string storage, array elements and hash-table slots;
/// measure the real number with Instruments (Allocations) on device.
public enum MemoryEstimate {
    /// Strings of up to 15 UTF-8 bytes are stored inline; longer ones need a heap object.
    static func string(_ text: String) -> Int {
        text.utf8.count <= 15 ? 16 : 16 + 32 + text.utf8.count
    }

    static func strings<S: Sequence>(_ values: S) -> Int where S.Element == String {
        values.reduce(0) { $0 + string($1) }
    }

    /// Dictionary and set slots, at a load factor of about 0.75.
    static func table(_ count: Int, slot: Int) -> Int { Int(Double(count) / 0.75) * slot }

    static func postings(_ map: [String: [Int]]) -> Int {
        table(map.count, slot: 16 + 8) + strings(map.keys) + map.values.reduce(0) { $0 + 32 + $1.count * 8 }
    }

    public static func bytes(of snapshot: IndexSnapshot, vectorDimension: Int) -> Int {
        var total = 0
        var countedTypes = Set<String>()
        for document in snapshot.documents {
            total += strings(document.nameTokens) + strings(document.aliasTokens)
            total += strings(document.allTokens) + table(document.allTokens.count, slot: 16)
            total += strings(document.trigrams) + table(document.trigrams.count, slot: 16)
            // The type field and its counts are shared by every device of a type (copy-on-write): count once.
            let firstOfType = countedTypes.insert(document.typeID).inserted
            for (field, tokens) in document.fieldTokens where field != .type || firstOfType {
                total += 32 + strings(tokens)
            }
            for (field, frequencies) in document.termFrequencies where field != .type || firstOfType {
                total += table(frequencies.count, slot: 24) + strings(frequencies.keys)
            }
            total += string(document.embeddingText) + string(document.compactKey) + string(document.contentHash)
            total += 256   // the record, type card reference, brand and room
        }
        total += postings(snapshot.inverted.postings)
        total += postings(snapshot.names.exact)
        total += postings(snapshot.fuzzy.trigramPostings) + postings(snapshot.fuzzy.phoneticPostings)
        let vocabulary = snapshot.vocabulary
        total += table(vocabulary.frequency.count, slot: 24) + strings(vocabulary.frequency.keys)
        total += strings(vocabulary.sortedTerms) + strings(vocabulary.nameTerms)
        total += vocabulary.termsByLength.values.reduce(0) { $0 + strings($1) }
        total += vocabulary.phoneticTerms.reduce(0) { $0 + string($1.key) + strings($1.value) }
        let facets = snapshot.facets
        let bitsetBytes = 32 + (facets.capacity + 63) / 64 * 8
        total += (facets.types.count + facets.brands.count + facets.rooms.count + 5) * bitsetBytes
        total += snapshot.count * vectorDimension * 4
        return total
    }
}

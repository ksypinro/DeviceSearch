import SearchCore
import SearchTestSupport

/// Generates realistic typos (design doc §17): neighbouring-key substitutions, dropped letters,
/// doubled letters and swapped neighbours. Deterministic for a given seed.
public struct TypoPerturber: Sendable {
    public enum Kind: CaseIterable, Sendable { case neighbour, drop, double, swap }

    static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map(Array.init)

    private var random: Mulberry32

    public init(seed: UInt32 = 11) {
        random = Mulberry32(seed: seed)
    }

    /// One typo in one word of 4+ letters. Returns nil when no word qualifies.
    public mutating func perturb(_ text: String) -> String? {
        var words = text.lowercased().split(separator: " ").map(String.init)
        let candidates = words.indices.filter { words[$0].count >= 4 && words[$0].allSatisfy(\.isLetter) }
        guard !candidates.isEmpty else { return nil }
        let index = candidates[Int(random.next() * Double(candidates.count))]
        let kind = Kind.allCases[Int(random.next() * Double(Kind.allCases.count))]
        guard let typo = apply(kind, to: Array(words[index])), typo != words[index] else { return nil }
        words[index] = typo
        return words.joined(separator: " ")
    }

    mutating func apply(_ kind: Kind, to word: [Character]) -> String? {
        // Never touch the first letter: people rarely mistype it, and it keeps the query recognizable.
        let position = 1 + Int(random.next() * Double(word.count - 1))
        var result = word
        switch kind {
        case .neighbour:
            guard let neighbour = neighbour(of: word[position]) else { return nil }
            result[position] = neighbour
        case .drop:
            result.remove(at: position)
        case .double:
            result.insert(word[position], at: position)
        case .swap:
            guard position < word.count - 1, word[position] != word[position + 1] else { return nil }
            result.swapAt(position, position + 1)
        }
        return String(result)
    }

    /// A key to the left or right of `character` on the same keyboard row.
    mutating func neighbour(of character: Character) -> Character? {
        for letters in Self.rows {
            guard let column = letters.firstIndex(of: character) else { continue }
            var options: [Character] = []
            if column > 0 { options.append(letters[column - 1]) }
            if column < letters.count - 1 { options.append(letters[column + 1]) }
            return options.isEmpty ? nil : options[Int(random.next() * Double(options.count))]
        }
        return nil
    }
}

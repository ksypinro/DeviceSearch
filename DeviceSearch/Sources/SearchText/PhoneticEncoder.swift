/// Maps a word to a key so that words that sound alike share a key ("fillips" and "philips" → "FLPS").
public protocol PhoneticEncoding: Sendable {
    func key(for word: String) -> String
}

/// A small Metaphone-style encoder (decision D01). Rules run in this exact order:
///
/// 1. Keep a–z only.
/// 2. Initial `kn gn pn wr ps` drop their first letter; initial `x` → `s`; initial `wh` → `w`.
/// 3. `ph`→`f`; `gh` before `t` or at the end → removed; `ck`→`k`; `sch`→`sk`; `tch`, `ch`, `sh` → `X`;
///    `th`→`0`; `c` before `i e y` → `s`; `c q`→`k`; `dg` before `i e y` → `j`; `d`→`t`;
///    `g` before `i e y` → `j`; `g`→`k`; `v`→`f`; `z`→`s`; `x`→`ks`.
/// 4. `w y` not followed by a vowel → removed; then `h` not followed by a vowel → removed.
/// 5. Keep the first letter; drop `a e i o u w y h` from the rest; collapse repeated letters; uppercase.
///
/// Each rule scans its input left to right; look-aheads read that rule's input, not its output.
public struct MetaphoneLite: PhoneticEncoding {
    public init() {}

    public func key(for word: String) -> String {
        var w = Array(word.lowercased().filter { $0 >= "a" && $0 <= "z" })
        guard !w.isEmpty else { return "" }

        // 2. Initial clusters.
        if w.count >= 2, ["kn", "gn", "pn", "wr", "ps"].contains(String(w[0...1])) { w.removeFirst() }
        if w.first == "x" { w[0] = "s" }
        if w.count >= 2, w[0] == "w", w[1] == "h" { w.remove(at: 1) }

        // 3. Substitutions.
        w = Self.replace(w, "ph", "f")
        w = Self.replace(w, "gh", "", when: { next in next == nil || next == "t" })
        w = Self.replace(w, "ck", "k")
        w = Self.replace(w, "sch", "sk")
        w = Self.replaceChShTch(w)
        w = Self.replace(w, "th", "0")
        w = Self.replace(w, "c", "s", when: Self.isFrontVowel)
        w = w.map { $0 == "c" || $0 == "q" ? "k" : $0 }
        w = Self.replace(w, "dg", "j", when: Self.isFrontVowel)
        w = w.map { $0 == "d" ? "t" : $0 }
        w = Self.replace(w, "g", "j", when: Self.isFrontVowel)
        w = w.map { $0 == "g" ? "k" : $0 }
        w = w.map { $0 == "v" ? "f" : $0 }
        w = w.map { $0 == "z" ? "s" : $0 }
        w = Self.replace(w, "x", "ks")

        // 4. Silent w, y, h.
        w = Self.removeUnlessVowelFollows(w, letters: ["w", "y"])
        w = Self.removeUnlessVowelFollows(w, letters: ["h"])
        guard let first = w.first else { return "" }

        // 5. Drop inner vowels, collapse doubles.
        let skipped: Set<Character> = ["a", "e", "i", "o", "u", "w", "y", "h"]
        var body: [Character] = [first]
        body.append(contentsOf: w.dropFirst().filter { !skipped.contains($0) })
        var collapsed: [Character] = []
        for character in body where collapsed.last != character { collapsed.append(character) }
        return String(collapsed).uppercased()
    }

    static func isFrontVowel(_ next: Character?) -> Bool { next == "i" || next == "e" || next == "y" }

    static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]

    /// Replaces every non-overlapping `pattern`, optionally only when the character after the match satisfies `when`.
    static func replace(_ input: [Character], _ pattern: String, _ replacement: String,
                        when condition: ((Character?) -> Bool)? = nil) -> [Character] {
        let p = Array(pattern)
        let r = Array(replacement)
        var output: [Character] = []
        var index = 0
        while index < input.count {
            if index + p.count <= input.count, Array(input[index..<(index + p.count)]) == p {
                let next = index + p.count < input.count ? input[index + p.count] : nil
                if condition?(next) ?? true {
                    output.append(contentsOf: r)
                    index += p.count
                    continue
                }
            }
            output.append(input[index])
            index += 1
        }
        return output
    }

    /// `tch`, `ch` and `sh` → `X` (the `t` of `tch` is consumed).
    static func replaceChShTch(_ input: [Character]) -> [Character] {
        var output: [Character] = []
        var index = 0
        while index < input.count {
            let rest = input.count - index
            if rest >= 3, input[index] == "t", input[index + 1] == "c", input[index + 2] == "h" {
                output.append("X"); index += 3; continue
            }
            if rest >= 2, input[index + 1] == "h", input[index] == "c" || input[index] == "s" {
                output.append("X"); index += 2; continue
            }
            output.append(input[index])
            index += 1
        }
        return output
    }

    static func removeUnlessVowelFollows(_ input: [Character], letters: Set<Character>) -> [Character] {
        var output: [Character] = []
        for (index, character) in input.enumerated() {
            if letters.contains(character) {
                let next = index + 1 < input.count ? input[index + 1] : nil
                if next == nil || !vowels.contains(next!) { continue }
            }
            output.append(character)
        }
        return output
    }
}

import Foundation

/// Stage S1 normalization (design doc §5). The same instance must be used at index time and query time.
///
/// Steps, in order:
/// 1. Split camel case (`LivingRoomTV` → `Living Room TV`) when requested.
/// 2. Compatibility decomposition (NFKD): full-width letters, ligatures and accents become plain letters plus marks.
/// 3. Remove Latin combining diacritics (`Café` → `Cafe`). Marks of other scripts (Bangla vowel signs) are kept.
/// 4. Lowercase.
/// 5. Expand abbreviations and symbols (`a/c` → `ac`, `&` → `and`).
/// 6. Drop apostrophes (`bob's` → `bobs`).
/// 7. Turn every other non-letter, non-number character into a space.
/// 8. Split letter–digit boundaries (`tv2` → `tv 2`).
/// 9. Collapse whitespace.
///
/// Implemented as character passes instead of Swift `Regex`, which is too slow for a 20 ms index rebuild.
public struct TextNormalizer: Sendable {
    /// A literal replacement applied on word boundaries.
    public struct Abbreviation: Sendable, Hashable, Codable {
        public var pattern: String
        public var replacement: String

        public init(pattern: String, replacement: String) {
            self.pattern = pattern
            self.replacement = replacement
        }
    }

    public var abbreviations: [Abbreviation] {
        didSet { asciiAbbreviations = Self.asciiTable(abbreviations) }
    }
    /// Byte copies of the abbreviations for the ASCII fast path; nil when any of them is not ASCII.
    private var asciiAbbreviations: [(pattern: [UInt8], replacement: [UInt8])]?

    public init(abbreviations: [Abbreviation] = TextNormalizer.defaultAbbreviations) {
        // Longest patterns first so "a.c." wins over shorter overlaps.
        let sorted = abbreviations.sorted { $0.pattern.count > $1.pattern.count }
        self.abbreviations = sorted
        self.asciiAbbreviations = Self.asciiTable(sorted)
    }

    static func asciiTable(_ abbreviations: [Abbreviation]) -> [(pattern: [UInt8], replacement: [UInt8])]? {
        let table = abbreviations.map { (Array($0.pattern.utf8), Array($0.replacement.utf8)) }
        let isASCII = table.allSatisfy { $0.0.allSatisfy { $0 < 0x80 } && $0.1.allSatisfy { $0 < 0x80 } }
        return isASCII ? table : nil
    }

    public static let defaultAbbreviations: [Abbreviation] = [
        Abbreviation(pattern: "a/c", replacement: "ac"),
        Abbreviation(pattern: "a.c.", replacement: "ac"),
        Abbreviation(pattern: "wi-fi", replacement: "wifi"),
        Abbreviation(pattern: "t.v.", replacement: "tv"),
        Abbreviation(pattern: "&", replacement: " and "),
        Abbreviation(pattern: "+", replacement: " plus "),
    ]

    /// Normalizes text to space-separated lowercase tokens.
    /// - Parameter splitCamelCase: Index time uses both `true` and `false` so "LivingRoomTV" matches
    ///   "living room tv" and "livingroomtv"; query time uses `true`.
    public func normalize(_ raw: String, splitCamelCase: Bool = true) -> String {
        // Most device names and queries are ASCII: the byte path gives the same result several times faster.
        if let table = asciiAbbreviations, raw.utf8.allSatisfy({ $0 < 0x80 }) {
            return Self.normalizeASCII(raw, splitCamelCase: splitCamelCase, abbreviations: table)
        }
        return normalizeGeneral(raw, splitCamelCase: splitCamelCase)
    }

    /// The character-level path, for any script.
    func normalizeGeneral(_ raw: String, splitCamelCase: Bool = true) -> String {
        var text = splitCamelCase ? Self.splitCamelCase(raw) : raw
        // ASCII has no compatibility decompositions and no combining marks, so most device names skip both.
        if !text.utf8.allSatisfy({ $0 < 0x80 }) {
            text = text.decomposedStringWithCompatibilityMapping
            text = Self.removeLatinDiacritics(text)
        }
        text = text.lowercased()
        var characters = Self.tightenSeparators(Array(text))
        characters = expandAbbreviations(characters)
        characters = characters.filter { !Self.apostrophes.contains($0) }
        characters = characters.map { $0.isLetter || $0.isNumber ? $0 : " " }
        characters = Self.splitLetterDigitBoundaries(characters)
        return String(characters).split(separator: " ").joined(separator: " ")
    }

    /// The same steps as `normalizeGeneral` on ASCII bytes (no decomposition or diacritics exist in ASCII).
    /// `NormalizerFastPathTests` checks that both paths agree.
    static func normalizeASCII(_ raw: String, splitCamelCase: Bool,
                               abbreviations: [(pattern: [UInt8], replacement: [UInt8])]) -> String {
        let space: UInt8 = 0x20, slash: UInt8 = 0x2F, dash: UInt8 = 0x2D
        func isUpper(_ b: UInt8) -> Bool { b >= 0x41 && b <= 0x5A }
        func isLower(_ b: UInt8) -> Bool { b >= 0x61 && b <= 0x7A }
        func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
        func isAlphanumeric(_ b: UInt8) -> Bool { isUpper(b) || isLower(b) || isDigit(b) }

        // 1. Camel case.
        var bytes: [UInt8] = []
        bytes.reserveCapacity(raw.utf8.count + 8)
        for byte in raw.utf8 {
            let count = bytes.count
            if splitCamelCase, isUpper(byte), count >= 2, isLower(bytes[count - 1]), isLower(bytes[count - 2]) {
                bytes.append(space)
            }
            bytes.append(byte)
        }
        // 4. Lowercase.
        for index in bytes.indices where isUpper(bytes[index]) { bytes[index] += 0x20 }
        // Tighten spaces around "/" and "-".
        var tight: [UInt8] = []
        tight.reserveCapacity(bytes.count)
        for (index, byte) in bytes.enumerated() {
            if byte == space {
                var next: UInt8?
                var probe = index + 1
                while probe < bytes.count { if bytes[probe] != space { next = bytes[probe]; break }; probe += 1 }
                let previous = tight.last
                if previous == slash || previous == dash || next == slash || next == dash { continue }
            }
            tight.append(byte)
        }
        // 5. Abbreviations, on word boundaries.
        var text = tight
        for (pattern, replacement) in abbreviations where !pattern.isEmpty && text.count >= pattern.count {
            let checkStart = isAlphanumeric(pattern[0])
            let checkEnd = isAlphanumeric(pattern[pattern.count - 1])
            var output: [UInt8] = []
            output.reserveCapacity(text.count)
            var index = 0
            while index < text.count {
                if index + pattern.count <= text.count, text[index..<(index + pattern.count)].elementsEqual(pattern) {
                    let startOK = !checkStart || index == 0 || !isAlphanumeric(text[index - 1])
                    let end = index + pattern.count
                    let endOK = !checkEnd || end == text.count || !isAlphanumeric(text[end])
                    if startOK && endOK {
                        output.append(contentsOf: replacement)
                        index = end
                        continue
                    }
                }
                output.append(text[index])
                index += 1
            }
            text = output
        }
        // 6–9. Drop apostrophes, other symbols become spaces, split letter–digit boundaries, collapse spaces.
        var result: [UInt8] = []
        result.reserveCapacity(text.count + 4)
        var previousKind = 0   // 0 none or space, 1 letter, 2 digit
        for byte in text where byte != 0x27 && byte != 0x60 {
            let kind = isDigit(byte) ? 2 : (isUpper(byte) || isLower(byte)) ? 1 : 0
            if kind == 0 {
                previousKind = 0
                continue
            }
            if previousKind == 0 {
                if !result.isEmpty { result.append(space) }
            } else if previousKind != kind {
                result.append(space)
            }
            result.append(byte)
            previousKind = kind
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// Normalized tokens (not stemmed).
    public func tokens(_ raw: String, splitCamelCase: Bool = true) -> [String] {
        let normalized = normalize(raw, splitCamelCase: splitCamelCase)
        return normalized.isEmpty ? [] : normalized.split(separator: " ").map(String.init)
    }

    // MARK: Steps

    static let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{2018}", "`", "\u{00B4}"]

    /// True when `splitCamelCase` would change the text, so camel-split and unsplit normalization differ.
    public static func hasCamelCaseBoundary(_ text: String) -> Bool {
        var previous: Character = " "
        var beforePrevious: Character = " "
        for character in text {
            if character.isUppercase && previous.isLowercase && beforePrevious.isLowercase { return true }
            beforePrevious = previous
            previous = character
        }
        return false
    }

    /// Inserts a space when two lowercase letters are followed by an uppercase letter ("LivingRoom" → "Living Room").
    /// "iPhone" stays intact because only one lowercase letter precedes the capital.
    static func splitCamelCase(_ text: String) -> String {
        var output: [Character] = []
        output.reserveCapacity(text.count + 4)
        for character in text {
            let count = output.count
            if character.isUppercase, count >= 2, output[count - 1].isLowercase, output[count - 2].isLowercase {
                output.append(" ")
            }
            output.append(character)
        }
        return String(output)
    }

    /// Removes combining marks from the Latin, Greek and Cyrillic diacritic blocks only.
    static func removeLatinDiacritics(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isLatinDiacritic(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    static func isLatinDiacritic(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0300...0x036F, 0x1AB0...0x1AFF, 0x1DC0...0x1DFF, 0x20D0...0x20FF, 0xFE20...0xFE2F: return true
        default: return false
        }
    }

    /// Removes spaces around "/" and "-" so "a / c" and "wi - fi" match their abbreviations.
    static func tightenSeparators(_ characters: [Character]) -> [Character] {
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        for (index, character) in characters.enumerated() {
            if character == " " {
                let previous = output.last
                let next = characters[(index + 1)...].first { $0 != " " }
                if previous == "/" || previous == "-" || next == "/" || next == "-" { continue }
            }
            output.append(character)
        }
        return output
    }

    func expandAbbreviations(_ characters: [Character]) -> [Character] {
        var output = characters
        for abbreviation in abbreviations {
            output = Self.replace(Array(abbreviation.pattern), with: Array(abbreviation.replacement), in: output)
        }
        return output
    }

    /// Replaces `pattern` where it is not glued to letters or digits on its alphanumeric ends.
    static func replace(_ pattern: [Character], with replacement: [Character], in text: [Character]) -> [Character] {
        guard !pattern.isEmpty, text.count >= pattern.count else { return text }
        var output: [Character] = []
        output.reserveCapacity(text.count)
        var index = 0
        let checkStart = pattern.first!.isLetter || pattern.first!.isNumber
        let checkEnd = pattern.last!.isLetter || pattern.last!.isNumber
        while index < text.count {
            if index + pattern.count <= text.count, Array(text[index..<(index + pattern.count)]) == pattern {
                let before = index > 0 ? text[index - 1] : nil
                let after = index + pattern.count < text.count ? text[index + pattern.count] : nil
                let startOK = !checkStart || !(before.map { $0.isLetter || $0.isNumber } ?? false)
                let endOK = !checkEnd || !(after.map { $0.isLetter || $0.isNumber } ?? false)
                if startOK && endOK {
                    output.append(contentsOf: replacement)
                    index += pattern.count
                    continue
                }
            }
            output.append(text[index])
            index += 1
        }
        return output
    }

    /// Inserts a space between a letter and a digit in either order ("tv2" → "tv 2").
    static func splitLetterDigitBoundaries(_ characters: [Character]) -> [Character] {
        var output: [Character] = []
        output.reserveCapacity(characters.count + 4)
        for character in characters {
            if let previous = output.last,
               (previous.isLetter && character.isNumber) || (previous.isNumber && character.isLetter) {
                output.append(" ")
            }
            output.append(character)
        }
        return output
    }
}

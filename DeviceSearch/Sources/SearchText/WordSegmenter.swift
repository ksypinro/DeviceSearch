/// Inserts spaces between words for scripts written without them (design doc §5).
/// Applied before normalization, at index time and query time.
public protocol WordSegmenting: Sendable {
    func segment(_ text: String) -> String
}

/// Leaves text unchanged. Used on platforms without NaturalLanguage and in tests.
public struct PassthroughSegmenter: WordSegmenting {
    public init() {}
    public func segment(_ text: String) -> String { text }
}

/// True for scalars of scripts that do not separate words with spaces (CJK, kana, Thai, Lao, Khmer, Myanmar).
public func needsWordSegmentation(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3040...0x30FF, 0x31F0...0x31FF,   // Hiragana, Katakana
         0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F, // CJK ideographs
         0x0E00...0x0E7F,                    // Thai
         0x0E80...0x0EFF,                    // Lao
         0x1780...0x17FF,                    // Khmer
         0x1000...0x109F:                    // Myanmar
        return true
    default:
        return false
    }
}

#if canImport(NaturalLanguage)
import NaturalLanguage

/// Word segmentation with `NLTokenizer`. Only runs when the text contains a script that needs it,
/// so Latin text is never changed.
public struct NLWordSegmenter: WordSegmenting {
    public init() {}

    public func segment(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: needsWordSegmentation) else { return text }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var words: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            words.append(String(text[range]))
            return true
        }
        return words.isEmpty ? text : words.joined(separator: " ")
    }
}
#endif

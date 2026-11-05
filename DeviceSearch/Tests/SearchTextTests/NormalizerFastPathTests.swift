import Testing
@testable import SearchText

/// The ASCII byte path must agree with the character path on every input (decision D02).
@Suite("Normalizer fast path")
struct NormalizerFastPathTests {
    let normalizer = TextNormalizer()

    func agree(_ text: String) -> Bool {
        normalizer.normalize(text, splitCamelCase: true) == normalizer.normalizeGeneral(text, splitCamelCase: true)
            && normalizer.normalize(text, splitCamelCase: false) == normalizer.normalizeGeneral(text, splitCamelCase: false)
    }

    @Test(arguments: [
        "LivingRoomTV", "iPhone dock", "a/c", "A / C unit", "wi - fi router", "t.v. 2", "TV2", "tv12b", "Bob's Lamp",
        "Rock & Roll", "C++ lab", "x--y", "a.c.", "ac/dc", "  spaced   out  ", "AC/DC", "Hue-Go", "under_score",
        "mixedCASEWord", "abcDefGhi", "123abc456", "it's`quoted`", "line\r\nbreak", "tab\tseparated", "", " ",
    ])
    func handPicked(_ text: String) {
        #expect(agree(text))
    }

    @Test func randomASCIIAgrees() {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
        let alphabet = Array("aAbBcCzZ019 /-.&+'`_#tTvV\t")
        for _ in 0..<3000 {
            let length = Int(next() % 14)
            let text = String((0..<length).map { _ in alphabet[Int(next() % UInt64(alphabet.count))] })
            #expect(agree(text), "\(text.debugDescription)")
        }
    }
}

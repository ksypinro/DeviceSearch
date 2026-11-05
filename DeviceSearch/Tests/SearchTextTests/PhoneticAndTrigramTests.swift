import Testing
@testable import SearchText

@Suite("Phonetic keys and trigrams")
struct PhoneticAndTrigramTests {
    let encoder = MetaphoneLite()

    @Test(arguments: [
        ("fillips", "FLPS"), ("philips", "FLPS"), ("dikin", "TKN"), ("daikin", "TKN"),
        ("lite", "LT"), ("light", "LT"), ("samsng", "SMSNK"), ("samsung", "SMSNK"),
        ("kitchen", "KXN"), ("thermostat", "0RMST"), ("hue", "H"), ("sonos", "SNS"),
        ("camera", "KMR"), ("garage", "KRJ"), ("christmas", "XRSTMS"), ("night", "NT"),
        ("whirlpool", "WRLPL"), ("ecobee", "EKB"), ("123", ""),
    ])
    func keys(word: String, expected: String) {
        #expect(encoder.key(for: word) == expected)
    }

    @Test func trigramsArePadded() {
        #expect(Trigrams.of("tv") == ["$tv", "tv$"])
        #expect(Trigrams.of("a") == ["$a$"])
        #expect(Trigrams.of("").isEmpty)  // "$$" is too short for a trigram
    }

    @Test func dice() {
        let a = Trigrams.of("livingroomtv")
        let b = Trigrams.of("livingroomtv2")
        #expect(Trigrams.dice(a, a) == 1)
        #expect(Trigrams.dice(a, b) > 0.8)
        #expect(Trigrams.dice(a, Trigrams.of("xyz")) == 0)
    }

    @Test func trigramsMatchTheCharacterPath() {
        for key in ["livingroomtv2", "tv", "a", "", "bobslamp"] {
            let padded = Array("$" + key + "$")
            let expected: Set<String> = padded.count < 3 ? [] : Set((0...(padded.count - 3)).map { String(padded[$0..<($0 + 3)]) })
            #expect(Trigrams.of(key) == expected)
        }
    }
}

import Testing
@testable import SearchText

@Suite("Text normalizer")
struct TextNormalizerTests {
    let normalizer = TextNormalizer()

    @Test(arguments: [
        ("LivingRoomTV2", "living room tv 2"),
        ("iPhone Dock", "iphone dock"),
        ("Café Lamp", "cafe lamp"),
        ("ＴＶ　２", "tv 2"),
        ("A / C unit", "ac unit"),
        ("a/c", "ac"),
        ("Wi - Fi Router", "wifi router"),
        ("Tom & Jerry", "tom and jerry"),
        ("Bob's Lamp", "bobs lamp"),
        ("bedroom’s light", "bedrooms light"),
        ("Hue-Go!", "hue go"),
        ("TV12", "tv 12"),
        ("12TV", "12 tv"),
        ("ÉCLAIR", "eclair"),
        ("Ångström", "angstrom"),
        ("Smart  Plug   3", "smart plug 3"),
        ("বেডরুমের এসি", "বেডরুমের এসি"),
        ("Klimaanlage Büro", "klimaanlage buro"),
        ("", ""),
    ])
    func normalizes(raw: String, expected: String) {
        #expect(normalizer.normalize(raw) == expected)
    }

    @Test func camelSplitCanBeDisabled() {
        #expect(normalizer.normalize("LivingRoomTV2", splitCamelCase: false) == "livingroomtv 2")
    }

    @Test func abbreviationsNeedWordBoundaries() {
        // "a/c" inside a longer token is not an abbreviation.
        #expect(normalizer.normalize("data/cable") == "data cable")
    }

    @Test func tokensSplitOnSpaces() {
        #expect(normalizer.tokens("Bedroom AC 2") == ["bedroom", "ac", "2"])
        #expect(normalizer.tokens("   ").isEmpty)
    }
}

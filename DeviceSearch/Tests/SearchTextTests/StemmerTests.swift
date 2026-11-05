import Testing
@testable import SearchText

@Suite("Stemmer")
struct StemmerTests {
    let stemmer = Stemmer()

    @Test(arguments: [
        ("lights", "light"), ("batteries", "battery"), ("switches", "switch"), ("boxes", "box"),
        ("dishes", "dish"), ("cameras", "camera"), ("acs", "ac"), ("tvs", "tv"),
        ("glass", "glass"), ("status", "status"), ("philips", "philips"), ("bus", "bus"),
        ("its", "its"), ("lens", "lens"), ("tv", "tv"), ("2", "2"), ("4k", "4k"),
    ])
    func stems(token: String, expected: String) {
        #expect(stemmer.stem(token) == expected)
    }

    @Test func pipelineStemsAfterNormalizing() {
        let pipeline = TextPipeline()
        #expect(pipeline.terms("Bedroom Lights") == ["bedroom", "light"])
        #expect(pipeline.key("LivingRoomTV") == "living room tv")
        #expect(pipeline.key("LivingRoomTV", splitCamelCase: false) == "livingroomtv")
    }
}

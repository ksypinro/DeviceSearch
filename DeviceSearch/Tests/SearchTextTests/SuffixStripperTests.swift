import Testing
@testable import SearchText

@Suite("Suffix stripper")
struct SuffixStripperTests {
    @Test func stripsBanglaPossessive() {
        let stripper = SuffixStripper(suffixes: ["ের", "য়ের", "র", "গুলো"])
        #expect(stripper.candidates(for: "বেডরুমের").first == "বেডরুম")
        #expect(stripper.candidates(for: "লাইটগুলো").first == "লাইট")
    }

    @Test func keepsAMinimumStem() {
        let stripper = SuffixStripper(suffixes: ["er"], minimumStemLength: 2)
        #expect(stripper.candidates(for: "her").isEmpty)
        #expect(stripper.candidates(for: "heater") == ["heat"])
    }

    @Test func segmenterLeavesLatinTextAlone() {
        #expect(PassthroughSegmenter().segment("Bedroom AC") == "Bedroom AC")
        #expect(needsWordSegmentation("中"))
        #expect(!needsWordSegmentation("a"))
    }
}

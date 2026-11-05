import Testing
@testable import SearchText

@Suite("Typing distance")
struct TypingDistanceTests {
    @Test(arguments: [
        ("samsng", "samsung", 1.0),      // missing letter
        ("bedrom", "bedroom", 0.5),      // missing doubled letter
        ("bedrooom", "bedroom", 0.5),    // extra doubled letter
        ("hallwya", "hallway", 0.7),     // swapped neighbours
        ("tc", "tv", 0.5),               // neighbouring key
        ("thermostst", "thermostat", 0.5),
        ("dikin", "daikin", 1.0),
        ("kitchn", "kitchen", 1.0),
        ("garaeg", "garage", 0.7),
        ("fillips", "philips", 2.5),     // too far: the phonetic fallback handles it
        ("lite", "light", 2.5),
        ("tv", "tv", 0.0),
        ("abc", "xyz", 3.0),
    ])
    func costs(typed: String, term: String, expected: Double) {
        #expect(abs(TypingDistance.distance(typed, term) - expected) < 1e-9)
    }

    @Test func earlyExitReturnsInfinityBeyondLimit() {
        #expect(TypingDistance.distance("fillips", "philips", limit: 1.5) == .infinity)
        #expect(TypingDistance.distance("samsng", "samsung", limit: 1.5) == 1.0)
        // Length difference alone exceeds the limit.
        #expect(TypingDistance.distance("ab", "abcdef", limit: 1.0) == .infinity)
    }

    @Test func neighbours() {
        #expect(KeyboardLayout.areNeighbours("c", "v"))
        #expect(KeyboardLayout.areNeighbours("a", "s"))
        #expect(KeyboardLayout.areNeighbours("e", "d"))
        #expect(!KeyboardLayout.areNeighbours("a", "p"))
        #expect(!KeyboardLayout.areNeighbours("a", "a"))
    }

    @Test func confidenceFormula() {
        #expect(TypingDistance.confidence(forCost: 0.5) == 0.85)
        #expect(TypingDistance.confidence(forCost: 1.0) == 0.7)
        #expect(TypingDistance.confidence(forCost: 1.5) == 0.55)
    }
}

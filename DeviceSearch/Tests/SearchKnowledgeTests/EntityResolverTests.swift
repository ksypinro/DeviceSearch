import Testing
import SearchCore
@testable import SearchKnowledge

@Suite("Entity resolver")
struct EntityResolverTests {
    let kb = try! KnowledgeBase.bundled()
    var resolver: EntityResolver { EntityResolver(knowledge: kb, pipeline: kb.makePipeline()) }

    @Test(arguments: [
        ("Samsung", "samsung"),
        ("Samsung Electronics Co., Ltd.", "samsung"),
        ("LG Electronics", "lg"),
        ("Signify (Philips Hue)", "philips-hue"),
        ("TP-Link", "tp-link-kasa"),
        ("Google Nest", "google-nest"),
    ])
    func resolvesKnownBrands(manufacturer: String, expected: String) {
        let brand = resolver.brand(for: manufacturer)
        #expect(brand.id == expected)
        #expect(brand.isKnown)
    }

    @Test func unknownManufacturerBecomesAdHocBrand() {
        let brand = resolver.brand(for: "Acme Gadgets")
        #expect(brand.id == "x-acme-gadget")
        #expect(!brand.isKnown)
        #expect(brand.name == "Acme Gadgets")
    }

    @Test func roomsResolveThroughAliases() {
        #expect(resolver.room(for: "Lounge")?.id == "living-room")
        #expect(resolver.room(for: "Living Room")?.isKnown == true)
        let custom = resolver.room(for: "Ayaan's Room")
        #expect(custom?.id == "room-ayaan-room")
        #expect(custom?.isKnown == false)
        #expect(resolver.room(for: "  ") == nil)
        #expect(resolver.room(for: nil) == nil)
    }
}

import Testing
@testable import SearchCore

@Suite("Bitset")
struct BitsetTests {
    @Test func insertContainsRemove() {
        var set = Bitset(capacity: 130)
        set.insert(0); set.insert(64); set.insert(129)
        #expect(set.contains(0) && set.contains(64) && set.contains(129))
        #expect(!set.contains(1))
        #expect(!set.contains(500))
        set.remove(64)
        #expect(set.members == [0, 129])
        #expect(set.count == 2)
    }

    @Test func algebra() {
        let a = Bitset(capacity: 10, members: [1, 2, 3, 4])
        let b = Bitset(capacity: 10, members: [3, 4, 5])
        #expect(a.union(b).members == [1, 2, 3, 4, 5])
        #expect(a.intersection(b).members == [3, 4])
        #expect(a.subtracting(b).members == [1, 2])
        #expect(Bitset.full(capacity: 3).members == [0, 1, 2])
        #expect(Bitset(capacity: 5).isEmpty)
    }
}

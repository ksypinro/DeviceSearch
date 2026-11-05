import Foundation
import Synchronization
import Testing
import SearchCore
import SearchIndex
import DeviceSearch
@testable import SearchPersonalization
import SearchTestSupport

@Suite("Decay")
struct DecayTests {
    @Test func halvesEveryHalfLife() {
        let start = Date(timeIntervalSince1970: 0)
        var value = DecayingValue(updatedAt: start)
        value.add(8, at: start, halfLifeDays: 21)
        #expect(abs(value.value(at: start.addingTimeInterval(21 * 86_400), halfLifeDays: 21) - 4) < 1e-9)
        value.add(1, at: start.addingTimeInterval(42 * 86_400), halfLifeDays: 21)
        #expect(abs(value.value - 3) < 1e-9)
    }
}

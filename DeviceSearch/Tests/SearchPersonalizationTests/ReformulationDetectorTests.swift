import Foundation
import Synchronization
import Testing
import SearchCore
import SearchIndex
import DeviceSearch
@testable import SearchPersonalization
import SearchTestSupport

@Suite("Reformulation detector")
struct ReformulationDetectorTests {
    let start = Date(timeIntervalSince1970: 0)

    @Test func aQuickDifferentQueryWithoutAPickIsAMiss() {
        var detector = ReformulationDetector()
        #expect(detector.settled("big screan", at: start) == nil)
        #expect(detector.settled("living room tv", at: start.addingTimeInterval(3)) == "big screan")
    }

    @Test(arguments: [
        ("bed", "bedroom ac", 2.0, false),           // typing on
        ("lamp", "lamp", 2.0, false),                 // same query
        ("lamp", "light", 8.0, false),                // too late
    ])
    func notMisses(first: String, second: String, seconds: Double, selected: Bool) {
        var detector = ReformulationDetector()
        _ = detector.settled(first, at: start)
        if selected { detector.selected(at: start) }
        #expect(detector.settled(second, at: start.addingTimeInterval(seconds)) == nil)
    }

    @Test func aSelectionInBetweenIsNotAMiss() {
        var detector = ReformulationDetector()
        _ = detector.settled("lamp", at: start)
        detector.selected(at: start.addingTimeInterval(1))
        #expect(detector.settled("light", at: start.addingTimeInterval(2)) == nil)
    }
}

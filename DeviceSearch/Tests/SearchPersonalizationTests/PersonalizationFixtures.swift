import Foundation
import Synchronization
import Testing
import SearchCore
import SearchIndex
import DeviceSearch
@testable import SearchPersonalization
import SearchTestSupport

/// A settable clock for decay tests.
final class TestClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { current.withLock { $0 } }
    func advance(days: Double) { current.withLock { $0 = $0.addingTimeInterval(days * 86_400) } }
    func advance(seconds: Double) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("personal-\(UUID().uuidString)")
}

func selection(_ key: String, _ device: DeviceID, position: Int = 1, lexical: Bool = true,
               at date: Date) -> SelectionRecord {
    SelectionRecord(queryKey: key, device: device, position: position, hadLexicalEvidence: lexical, date: date)
}

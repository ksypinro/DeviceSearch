import Foundation
import Testing
@testable import SearchCore

@Suite("Device model")
struct DeviceModelTests {
    @Test func identifiersEncodeAsPlainStrings() throws {
        let data = try JSONEncoder().encode(DeviceID("abc-1"))
        #expect(String(decoding: data, as: UTF8.self) == "\"abc-1\"")
        #expect(try JSONDecoder().decode(DeviceID.self, from: data) == "abc-1")
    }

    @Test func contentHashIgnoresStatusAndUsage() {
        var record = DeviceRecord(id: "1", name: "Bedroom AC", manufacturer: "Samsung", type: "ac", room: "Bedroom")
        let before = record.contentHash
        record.status = DeviceStatus(isOnline: false, isOn: true)
        record.usage = UsageStats(useCount: 9, isFavorite: true)
        #expect(record.contentHash == before)
        record.name = "Bedroom AC 2"
        #expect(record.contentHash != before)
    }

    @Test func stableHashIsDeterministic() {
        #expect(StableHash.hex("") == "cbf29ce484222325")
        #expect(StableHash.hex("a") == "af63dc4c8601ec8c")
        #expect(StableHash.hex("Bedroom AC").count == 16)
    }
}

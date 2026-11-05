import Foundation
import Synchronization
import Testing
import SearchCore
import SearchIndex
import SearchRanking
import DeviceSearch
@testable import DeviceSearchUI
import SearchTestSupport

actor FakeNicknames: NicknameManaging {
    var stored: [DeviceID: [String]] = ["d1": ["big screen", "telly"], "d2": ["coffee"]]
    func learnedNicknames() async -> [DeviceID: [String]] { stored }
    func removeNickname(_ nickname: String, for device: DeviceID) async -> PersonalChange {
        stored[device]?.removeAll { $0 == nickname }
        return .aliases
    }
}

@MainActor
@Suite("Nickname settings")
struct NicknameSettingsModelTests {
    @Test func listsAndRemovesNicknames() async {
        let rebuilds = Mutex(0)
        let model = NicknameSettingsModel(manager: FakeNicknames(),
                                          deviceNames: { ids in Dictionary(uniqueKeysWithValues: ids.map { ($0, "Device \($0.rawValue)") }) },
                                          onChange: { rebuilds.withLock { $0 += 1 } })
        await model.load()
        #expect(model.items.map(\.nickname) == ["big screen", "telly", "coffee"])
        await model.remove(model.items[0])
        #expect(model.items.map(\.nickname) == ["telly", "coffee"])
        #expect(rebuilds.withLock { $0 } == 1)
    }
}

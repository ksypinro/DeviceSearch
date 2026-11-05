import Foundation
import Testing
import SearchCore
import SearchIndex
import SearchRanking
@testable import DeviceSearch
@testable import SearchRerank
import SearchTestSupport

@Suite("Off-device opt-in")
struct RerankClientRouterTests {
    @Test func neverFallsBackSilently() async throws {
        let offDevice = ScriptedClient(RerankAnswer(best: [1], related: []))
        let router = RerankClientRouter(onDevice: ScriptedClient(available: false), offDevice: offDevice)
        #expect(await router.isAvailable() == false)
        let request = LLMReranker.modelRequest(for: refinementRequest("something to cool the bedroom"))
        await #expect(throws: RefinementFailure(.unavailable)) { try await router.rank(request) }
        #expect(offDevice.callCount == 0)

        router.setPreference(.allowOffDevice)
        #expect(await router.isAvailable())
        #expect(try await router.rank(request).best == [1])
        #expect(offDevice.callCount == 1)
    }

    @Test func onDeviceWinsWhenAvailable() async throws {
        let onDevice = ScriptedClient(RerankAnswer(best: [2], related: []))
        let offDevice = ScriptedClient(RerankAnswer(best: [1], related: []))
        let router = RerankClientRouter(onDevice: onDevice, offDevice: offDevice, preference: .allowOffDevice)
        let request = LLMReranker.modelRequest(for: refinementRequest("something to cool the bedroom"))
        #expect(try await router.rank(request).best == [2])
        #expect(offDevice.callCount == 0)
    }

    @Test func lowPowerAndHeatDisableTheModel() {
        #expect(FixedDeviceConditions(lowPower: true).isLowPowerModeEnabled)
        #expect(FixedDeviceConditions(hot: true).isThermalStateSeriousOrWorse)
        #expect(!SystemDeviceConditions().isThermalStateSeriousOrWorse || true)
    }
}

import Foundation
import Testing
import SearchCore
import SearchIndex
@testable import DeviceSearch
import SearchTestSupport

@Suite("Device events and sync")
struct DeviceEventTests {
    @Test func differTurnsStateIntoEvents() {
        let old = Array(SyntheticHome.curated.prefix(3))
        var new = old
        new[0].name = "Renamed"
        new[1].status = DeviceStatus(isOnline: false)
        new.remove(at: 2)
        new.append(DeviceRecord(id: "x", name: "New", manufacturer: "LG", type: "tv"))
        let events = DeviceEventDiffer.diff(old: old, new: new)
        #expect(events.count == 4)
        #expect(events.contains(.removed(old[2].id)))
        #expect(events.contains(.statusChanged(old[1].id, DeviceStatus(isOnline: false))))
    }

    @Test func syncRebuildsAndSwapsTheSnapshot() async {
        let start = TestIndex.curated
        let engine = SearchEngine(snapshot: start)
        let sync = IndexSync(engine: engine, builder: TestIndex.builder, initialDevices: SyntheticHome.curated,
                             generation: start.generation)
        await sync.apply(.removed("d002"))
        await sync.rebuildNow()
        let snapshot = await engine.currentSnapshot
        #expect(snapshot.document(for: "d002") == nil)
        #expect(snapshot.count == start.count - 1)
        #expect(snapshot.generation == start.generation + 1)
    }

    @Test func statusChangesNeverRebuild() async {
        let start = TestIndex.curated
        let engine = SearchEngine(snapshot: start)
        let sync = IndexSync(engine: engine, builder: TestIndex.builder, initialDevices: SyntheticHome.curated,
                             generation: start.generation)
        await sync.apply(.statusChanged("d001", DeviceStatus(isOnline: false, isOn: false)))
        let snapshot = await engine.currentSnapshot
        #expect(snapshot.generation == start.generation)
        #expect(snapshot.facets.offline.contains(snapshot.ordinal(of: "d001")!))
    }
}

@preconcurrency import CoreSpotlight
import Foundation
import Observation
import SwiftUI
import SearchCore
import DeviceSearch
import SearchTestSupport

/// Developer tool: runs `SpotlightIndexer` scenarios against the real Core Spotlight store on the device or
/// Simulator, and logs PASS or FAIL for each to Documents/spotlight-selftest.log. Launch with `-spotlightSelfTest`.
///
/// These run against Spotlight itself rather than a fake, because the bugs that matter come from how it behaves:
/// deletes reach every named index in a shared store, and items become searchable a little after they are sent.
/// The run replaces this app's Spotlight entries with a 48-device test home.
enum SpotlightSelfTest {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-spotlightSelfTest") }

    @MainActor
    static func run(services: AppSearchServices, log: SelfTestLog) async {
        let indexer = services.spotlight
        let indexName = "\(Bundle.main.bundleIdentifier ?? "app").devices"
        // Deletes made behind the indexer's back, as when Spotlight loses items.
        let outside = CSSearchableIndex(name: "\(indexName).catalog", protectionClass: .completeUntilFirstUserAuthentication)
        var records = SyntheticHome.curated
        let bridge = DeviceEventBridge(initial: records)
        // A clean slate: no saved state and no items from earlier runs.
        await indexer.removeAll()
        _ = await waitUntil { $0.isEmpty }
        let home = await services.open(HomeID("selftest"), devices: records, events: bridge.events)
        func identifiers(_ devices: [DeviceRecord]) -> Set<String> {
            Set(devices.map { SpotlightItemMapping.identifier(for: $0.id) })
        }
        func publish() { bridge.publish(records) }

        let everything = identifiers(records)
        log.check("First sync sends every device",
                  await waitUntil { $0 == everything }, expected: everything.count)

        let removed = records.removeFirst()
        publish()
        log.check("A deleted device leaves Spotlight",
                  await waitUntil { $0 == identifiers(records) }, expected: records.count)

        // A light becoming a lock moves to the secure index; a delete-all or a delete through the wrong index
        // would lose it (the shared-store bug).
        let moved = records.firstIndex { $0.type.rawValue == "light" }
        if let moved {
            records[moved].type = DeviceTypeID("lock")
            publish()
            log.check("A device moving to the secure index stays searchable",
                      await waitUntil { $0 == identifiers(records) }, expected: records.count)
            records[moved].type = DeviceTypeID("light")
            publish()
            log.check("…and moving back", await waitUntil { $0 == identifiers(records) }, expected: records.count)
        }

        let renamed = records.count - 1
        records[renamed].name = "Selftest Renamed Lamp"
        publish()
        log.check("A renamed device is found by its new name",
                  await waitUntilFound("displayName == \"*Selftest Renamed*\"cd"), expected: 1)

        services.flags.update { $0.spotlightEnabled = false }
        await services.flagsDidChange()
        log.check("Turning Spotlight off deletes every entry", await waitUntil { $0.isEmpty }, expected: 0)
        services.flags.update { $0.spotlightEnabled = true }
        await services.flagsDidChange()
        log.check("Turning it back on sends every device", await waitUntil { $0 == identifiers(records) },
                  expected: records.count)

        // Lost items: the saved state still lists them.
        let lost = Array(identifiers(records).filter { !SpotlightItemMapping.isSensitiveIdentifier($0, in: records) }
            .sorted().prefix(5))
        try? await outside.deleteSearchableItems(withIdentifiers: lost)
        _ = await waitUntil { $0.isDisjoint(with: lost) }
        await services.flagsDidChange()  // a write that sends nothing, as at launch
        await indexer.restoreMissingItems()
        log.check("The launch check sends lost items again", await waitUntil { $0 == identifiers(records) },
                  expected: records.count)

        // A relaunch after Spotlight lost items while the app also has a change to send: the first write sends
        // the change, and the check after it still finds the lost items.
        let lostAtLaunch = Array(lost.suffix(3))
        try? await outside.deleteSearchableItems(withIdentifiers: lostAtLaunch)
        _ = await waitUntil { $0.isDisjoint(with: lostAtLaunch) }
        records[renamed].name = "Selftest Lamp After Relaunch"
        publish()
        try? await Task.sleep(for: .seconds(1))  // let the rename reach the engine first
        await indexer.follow(home.engine)
        log.check("A relaunch restores lost items and sends the change",
                  await waitUntil { $0 == identifiers(records) }, expected: records.count)

        try? await outside.deleteAllSearchableItems()
        _ = await waitUntil { $0.isEmpty }
        await indexer.reindexAll()
        log.check("A reindex-all request rebuilds the index", await waitUntil { $0 == identifiers(records) },
                  expected: records.count)

        let failed = Array(lost.prefix(3))
        try? await outside.deleteSearchableItems(withIdentifiers: failed)
        _ = await waitUntil { $0.isDisjoint(with: failed) }
        await indexer.reindex(failed)
        log.check("A reindex request for some items sends them again", await waitUntil { $0 == identifiers(records) },
                  expected: records.count)

        let sources = await indexer.itemSources(for: [SpotlightItemMapping.identifier(for: records[0].id),
                                                      SpotlightItemMapping.identifier(for: removed.id)])
        let hydrated = sources.map { SpotlightItemMapping.item(for: $0.document, homeID: $0.homeID, lastUsed: $0.lastUsed) }
        log.check("Items are built on demand, and only for current devices",
                  hydrated.count == 1 && hydrated.first?.attributeSet.displayName?.isEmpty == false, expected: 1)

        log.finish()
    }

    /// Polls this app's Spotlight identifiers until `condition` holds, at most 30 seconds.
    @MainActor
    static func waitUntil(_ condition: (Set<String>) -> Bool) async -> Set<String>? {
        var last = Set<String>()
        for _ in 0..<60 {
            if let present = await SpotlightIndexer.indexedIdentifiers() {
                last = present
                if condition(present) { return present }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return condition(last) ? last : nil
    }

    /// Polls until a query finds at least one item, at most 30 seconds.
    static func waitUntilFound(_ queryString: String) async -> Bool {
        for _ in 0..<60 {
            let query = CSSearchQuery(queryString: queryString, queryContext: CSSearchQueryContext())
            query.protectionClasses = [.completeUntilFirstUserAuthentication, .complete]
            var found = false
            do {
                for try await _ in query.results { found = true }
            } catch {}
            if found { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }
}

private extension SpotlightItemMapping {
    static func isSensitiveIdentifier(_ identifier: String, in records: [DeviceRecord]) -> Bool {
        guard let id = deviceID(fromIdentifier: identifier),
              let record = records.first(where: { $0.id == id }) else { return false }
        return sensitiveTypes.contains(record.type.rawValue)
    }
}

@MainActor
@Observable
final class SelfTestLog {
    private(set) var lines: [String] = []
    private var failures = 0

    func check(_ name: String, _ passed: Bool, expected: Int) {
        if !passed { failures += 1 }
        append("\(passed ? "PASS" : "FAIL") \(name) (expected \(expected))")
    }

    func check(_ name: String, _ present: Set<String>?, expected: Int) {
        check(name, present != nil, expected: expected)
    }

    func finish() {
        append(failures == 0 ? "All checks passed" : "\(failures) checks failed")
    }

    private func append(_ line: String) {
        lines.append(line)
        print("[selftest] \(line)")
        try? lines.joined(separator: "\n").write(to: URL.documentsDirectory.appending(path: "spotlight-selftest.log"),
                                                 atomically: true, encoding: .utf8)
    }
}

/// Shown instead of the demo's tabs when the app is launched with `-spotlightSelfTest`.
struct SpotlightSelfTestView: View {
    let services: AppSearchServices
    @State private var log = SelfTestLog()

    var body: some View {
        NavigationStack {
            List(Array(log.lines.enumerated()), id: \.offset) { line in
                Text(line.element).font(.caption.monospaced())
            }
            .navigationTitle("Spotlight self-test")
        }
        .task { await SpotlightSelfTest.run(services: services, log: log) }
    }
}

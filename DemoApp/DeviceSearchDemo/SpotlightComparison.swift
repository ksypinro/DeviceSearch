import CoreSpotlight
import Foundation
import Observation
import Synchronization
import SwiftUI
import SearchCore
import SearchIndex
import DeviceSearch
import SearchEvaluation
import SearchRerank
import SearchSemantic
import SearchTestSupport
#if canImport(FoundationModels)
import FoundationModels
#endif
// `SpotlightSearchTool` comes from the CoreSpotlight + FoundationModels overlay, whose Intel simulator slice is
// empty, so the tool code is built for arm64 only.

/// Developer tool: runs the golden set through this app's search and through Spotlight's own search APIs over the
/// same 500-device home (the items `SpotlightIndexer` donates), then writes `spotlight-comparison.md` and
/// `spotlight-comparison.json` to Documents.
///
/// Launch with `-compareSpotlight`. `-toolSample N` sets how many queries per category go to
/// `SpotlightSearchTool` (default 12), which needs iOS 27 and Apple Intelligence; `-permissiveGuardrails` and
/// `-probeOnly` are described in the demo README.
enum SpotlightComparison {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-compareSpotlight") }

    static var toolSample: Int {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-toolSample"), index + 1 < arguments.count,
              let value = Int(arguments[index + 1]) else { return 12 }
        return value
    }

    enum System: String, CaseIterable, Codable, Sendable {
        case typing = "In-app (typing)"
        case submitted = "In-app (submitted)"
        case userQuery = "CSUserQuery"
        case userQueryArrival = "CSUserQuery (arrival order)"
        case userQueryLexical = "CSUserQuery (semantic off)"
        case tool = "SpotlightSearchTool"
    }

    struct Outcome: Codable, Sendable {
        var ids: [String]
        var milliseconds: Double
        var error: String?
        var answer: String?
    }

    struct Row: Codable, Sendable {
        var id: String
        var text: String
        var category: String
        var expected: [String]
        var results: [String: Outcome] = [:]
    }

    /// Both partitions: the catalog and the `.complete` index for locks, cameras, doorbells and garage doors.
    static let protectionClasses: [FileProtectionType] = [.completeUntilFirstUserAuthentication, .complete]
    static let homeID = HomeID("demo-large")

    // MARK: Run

    @MainActor
    static func run(services: AppSearchServices, progress: ComparisonProgress) async {
        progress.log("Opening the 500-device home")
        let (home, embedder) = await makeHome(services: services, devices: SyntheticHome.make(count: 500))
        let engine = home.engine
        await engine.prewarm()
        await services.spotlight.follow(engine)
        let snapshot = await engine.currentSnapshot
        progress.log("Embeddings (\(embedder)): \(snapshot.vectors.warmedCount) devices")
        let indexed = await waitForSpotlight(expected: snapshot.count)
        progress.log("Spotlight holds \(indexed) of \(snapshot.count) devices")

        let queries = GoldenSetBuilder(snapshot: snapshot).build()
        var rows = queries.map { Row(id: $0.id, text: $0.text, category: $0.category.rawValue,
                                     expected: expectedLabels($0.expectation, snapshot)) }
        let model = modelStatus()
        var header = ["Home: \(snapshot.count) devices; Spotlight items: \(indexed); queries: \(queries.count)",
                      "In-app meaning layer: \(embedder), \(snapshot.vectors.warmedCount) devices embedded",
                      "On-device model: \(model)"]
        func save() { write(rows: rows, queries: queries, snapshot: snapshot, header: header) }

        CSUserQuery.prepareProtectionClasses(protectionClasses)
        _ = await userQuery("light", semantic: true)  // warm-up; semantic search often fails on the first query
        for line in await probeUserQuery() {
            progress.log(line)
            header.append(line)
        }
        if ProcessInfo.processInfo.arguments.contains("-probeOnly") { return save() }

        for mode in [SearchMode.typing, .submitted] {
            let system: System = mode == .typing ? .typing : .submitted
            for (index, query) in queries.enumerated() {
                let start = ContinuousClock.now
                let phases = await engine.searchAll(query.text, mode: mode)
                let elapsed = ContinuousClock.now - start
                let last = phases.last
                let ids = last.map { $0.noMatchesMessage == nil ? $0.results.map(\.id.rawValue) : [] } ?? []
                rows[index].results[system.rawValue] = Outcome(ids: ids, milliseconds: milliseconds(elapsed))
                if index % 50 == 0 { progress.log("\(system.rawValue) \(index)/\(queries.count)") }
            }
            save()
        }

        for semantic in [true, false] {
            for (index, query) in queries.enumerated() {
                let (ranked, arrival, elapsed, error) = await userQuery(query.text, semantic: semantic)
                if semantic {
                    rows[index].results[System.userQuery.rawValue] = Outcome(ids: ranked, milliseconds: elapsed, error: error)
                    rows[index].results[System.userQueryArrival.rawValue] = Outcome(ids: arrival, milliseconds: elapsed, error: error)
                } else {
                    rows[index].results[System.userQueryLexical.rawValue] = Outcome(ids: ranked, milliseconds: elapsed, error: error)
                }
                if index % 50 == 0 { progress.log("CSUserQuery semantic \(semantic) \(index)/\(queries.count)") }
            }
            save()
        }

        #if canImport(FoundationModels) && arch(arm64)
        if #available(iOS 27.0, *), SystemLanguageModel.default.isAvailable {
            let sample = Dictionary(grouping: queries.indices, by: { queries[$0].category })
                .values.flatMap { $0.prefix(toolSample) }.sorted()
            for (done, index) in sample.enumerated() {
                let outcome = await withTimeout(seconds: 90) { await searchWithTool(queries[index].text) }
                rows[index].results[System.tool.rawValue] = outcome
                    ?? Outcome(ids: [], milliseconds: 90_000, error: "timed out after 90 s")
                if done % 10 == 0 { progress.log("SpotlightSearchTool \(done)/\(sample.count)") }
                if done % 20 == 0 { save() }
            }
        } else {
            header.append("SpotlightSearchTool skipped: needs iOS 27 and an available model")
        }
        #else
        header.append("SpotlightSearchTool skipped: not built for this architecture")
        #endif
        save()
        progress.log("Done. Report in Documents/spotlight-comparison.md")
    }

    /// The app's components for one home (`AppSearchServices`), except that the embedder falls back to the lexicon
    /// when Apple's contextual model cannot load: the Simulator cannot compile it.
    static func makeHome(services: AppSearchServices, devices: [DeviceRecord]) async -> (HomeSearch, String) {
        var embedder: any TextEmbedding = LexiconEmbedding(knowledge: services.knowledge)
        if let contextual = NLContextualEmbedder(language: .english), (try? await contextual.embed("ceiling light")) != nil {
            embedder = contextual
        }
        let provider = MeaningRetrievalProvider(embedder: embedder, knowledge: services.knowledge)
        let model = FoundationModelsClient(model: languageModel)
        var components = DeviceSearchComponents(knowledge: services.knowledge, flags: services.flags,
                                                telemetry: services.telemetry)
        components.meaning = provider
        components.refiner = LLMReranker(client: model)
        components.rewriter = LLMQueryRewriter(client: model)
        components.personal = services.personalization.store(for: homeID)
        let home = await HomeSearch.make(homeID: homeID, devices: devices, components: components)
        await provider.waitUntilWarm()
        return (home, embedder.modelVersion)
    }

    /// Waits until Spotlight returns every device (or the count stops growing), at most two minutes.
    static func waitForSpotlight(expected: Int) async -> Int {
        var last = -1
        var stableFor = 0
        for _ in 0..<60 {
            let count = await indexedCount()
            if count >= expected { return count }
            stableFor = count == last && count > 0 ? stableFor + 1 : 0
            if stableFor >= 5 { return count }
            last = count
            try? await Task.sleep(for: .seconds(2))
        }
        return last
    }

    static func indexedCount() async -> Int {
        let context = CSSearchQueryContext()
        context.fetchAttributes = []
        let query = CSSearchQuery(queryString: "title == \"*\"", queryContext: context)
        query.protectionClasses = protectionClasses
        var count = 0
        do {
            for try await _ in query.results { count += 1 }
        } catch {
            return -1
        }
        return count
    }

    // MARK: Spotlight searches

    /// Spotlight's in-app search with the default context (ranked results). Some combinations of
    /// `maxResultCount`, `maxRankedResultCount` and `maxSuggestionCount` return nothing at all; `probeUserQuery`
    /// records which.
    @MainActor
    static func userQuery(_ text: String, semantic: Bool) async -> (ranked: [String], arrival: [String], ms: Double, error: String?) {
        let context = CSUserQueryContext()
        context.fetchAttributes = ["displayName"]
        context.disableSemanticSearch = !semantic
        let query = CSUserQuery(userQueryString: text, userQueryContext: context)
        query.protectionClasses = protectionClasses
        var items: [CSUserQuery.Item] = []
        let start = ContinuousClock.now
        do {
            for try await response in query.responses {
                if case .item(let item) = response { items.append(item) }
            }
        } catch {
            return ([], [], milliseconds(ContinuousClock.now - start), String(describing: error))
        }
        let elapsed = milliseconds(ContinuousClock.now - start)
        func ids(_ items: [CSUserQuery.Item]) -> [String] {
            items.compactMap { SpotlightItemMapping.deviceID(fromIdentifier: $0.item.uniqueIdentifier)?.rawValue }
        }
        return (ids(items.sorted()), ids(items), elapsed, nil)
    }

    /// Result counts for one query under each `CSUserQuery` setting the comparison uses, and for plain
    /// `CSSearchQuery` predicates, to tell an empty answer from a setting Spotlight rejects.
    @MainActor
    static func probeUserQuery(_ text: String = "bedroom") async -> [String] {
        func count(_ configure: (CSUserQueryContext) -> Void, protect: Bool) async -> String {
            let context = CSUserQueryContext()
            configure(context)
            let query = CSUserQuery(userQueryString: text, userQueryContext: context)
            if protect { query.protectionClasses = protectionClasses }
            var items = 0
            var suggestions = 0
            do {
                for try await response in query.responses {
                    if case .item = response { items += 1 } else { suggestions += 1 }
                }
            } catch {
                return "error \(error)"
            }
            return "\(items) items, \(suggestions) suggestions"
        }
        func predicate(_ string: String) async -> String {
            let query = CSSearchQuery(queryString: string, queryContext: CSSearchQueryContext())
            query.protectionClasses = protectionClasses
            var items = 0
            do {
                for try await _ in query.results { items += 1 }
            } catch {
                return "error \(error)"
            }
            return "\(items) items"
        }
        let recipe = await count({ context in
            context.fetchAttributes = ["displayName"]
            context.maxResultCount = 500
            context.enableRankedResults = true
            context.maxRankedResultCount = 20
            context.maxSuggestionCount = 0
        }, protect: true)
        return [
            "Probe “\(text)”, default context: \(await count({ _ in }, protect: false))",
            "Probe, default context + protection classes: \(await count({ _ in }, protect: true))",
            "Probe, comparison settings: \(await count({ $0.fetchAttributes = ["displayName"] }, protect: true))",
            "Probe, semantic off: \(await count({ $0.disableSemanticSearch = true }, protect: false))",
            "Probe, maxResultCount 20 + maxRankedResultCount 20: \(await count({ $0.maxResultCount = 20; $0.maxRankedResultCount = 20 }, protect: false))",
            "Probe, maxResultCount 500 + maxRankedResultCount 20: \(await count({ $0.maxResultCount = 500; $0.maxRankedResultCount = 20 }, protect: false))",
            "Probe, maxRankedResultCount 20 + maxSuggestionCount 0: \(await count({ $0.maxRankedResultCount = 20; $0.maxSuggestionCount = 0 }, protect: false))",
            "Probe, maxResultCount 500 + maxSuggestionCount 0: \(await count({ $0.maxResultCount = 500; $0.maxSuggestionCount = 0 }, protect: false))",
            "Probe, all five recipe settings: \(recipe)",
            "Probe, CSSearchQuery displayName: \(await predicate("displayName == \"*\(text)*\"cd"))",
            "Probe, CSSearchQuery tokenized: \(await predicate("displayName == \"\(text)*\"cdwt"))",
            "Probe, CSSearchQuery textContent: \(await predicate("textContent == \"*\(text)*\"cd"))",
        ]
    }

    #if canImport(FoundationModels) && arch(arm64)
    static let toolInstructions = """
        You find devices in one smart home. Each search result is one device: its title is the room and the \
        device name, and its description gives the device type, brand and room. Always use the search tool, \
        then reply with the titles of the matching devices only.
        """

    /// The iOS 27 retrieval tool: the model writes the Spotlight query; the items it returns are the ranking.
    @available(iOS 27.0, *)
    static func searchWithTool(_ text: String) async -> Outcome {
        var source = CoreSpotlightSource(fetchAttributes: [.displayName, .contentDescription, .containerTitle])
        source.maximumResultCount = 30
        let tool = SpotlightSearchTool(configuration: .init(
            sources: [.coreSpotlight(source)],
            guide: .init(level: .focused(.items(.init(title: [.displayName, .title],
                                                       text: [.contentDescription, .textContent, .keywords]))),
                         format: .compact)))
        let found = FoundIdentifiers()
        let listener = Task {
            for await reply in tool.searchResults {
                let items: [CSSearchableItem] = switch reply.content {
                case .items(let items): items
                case .scoredItems(let scored): scored.sorted { $0.score > $1.score }.map(\.item)
                case .groupedItems(let groups): groups.values.flatMap { $0 }
                default: []
                }
                found.append(items.compactMap { SpotlightItemMapping.deviceID(fromIdentifier: $0.uniqueIdentifier)?.rawValue })
            }
        }
        defer { listener.cancel() }
        let session = LanguageModelSession(model: languageModel, tools: [tool], instructions: toolInstructions)
        let start = ContinuousClock.now
        do {
            let response = try await session.respond(to: "Find the devices for this search: \(text)")
            try? await Task.sleep(for: .milliseconds(200))  // let the last reply reach the listener
            return Outcome(ids: found.ids, milliseconds: milliseconds(ContinuousClock.now - start - .milliseconds(200)),
                           answer: String(response.content.prefix(300)))
        } catch {
            return Outcome(ids: found.ids, milliseconds: milliseconds(ContinuousClock.now - start),
                           error: String(describing: error))
        }
    }
    #endif

    /// `-permissiveGuardrails` uses `permissiveContentTransformations` for the in-app re-rank and the tool alike:
    /// the iOS 27 beta Simulator fails every default-guardrail request in its content sanitizer.
    static var languageModel: SystemLanguageModel {
        ProcessInfo.processInfo.arguments.contains("-permissiveGuardrails")
            ? SystemLanguageModel(guardrails: .permissiveContentTransformations) : .default
    }

    static func modelStatus() -> String {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return "available"
        case .unavailable(let reason): return "unavailable (\(reason))"
        }
        #else
        return "not in this SDK"
        #endif
    }

    // MARK: Report

    static func expectedLabels(_ expectation: GoldenExpectation, _ snapshot: IndexSnapshot) -> [String] {
        switch expectation {
        case .device(let id): [label(id, snapshot)]
        case .set(let ids): ids.map { label($0, snapshot) }
        case .graded(let gains): gains.sorted { $0.value > $1.value }.map { "\(label($0.key, snapshot)) (\($0.value))" }
        }
    }

    static func label(_ id: DeviceID, _ snapshot: IndexSnapshot) -> String {
        guard let device = snapshot.document(for: id)?.device else { return id.rawValue }
        return SpotlightItemMapping.displayName(name: device.name, room: device.room)
    }

    struct Scores {
        var count = 0
        var success: [Double] = [], mrr: [Double] = [], hit10: [Double] = [], ndcg: [Double] = []
        var precision: [Double] = [], recall: [Double] = []
        var zero = 0, errors = 0
        var latency: [Duration] = []

        mutating func add(_ outcome: Outcome, _ expectation: GoldenExpectation) {
            let ranked = outcome.ids.map { DeviceID($0) }
            count += 1
            if ranked.isEmpty { zero += 1 }
            if outcome.error != nil { errors += 1 }
            latency.append(.milliseconds(outcome.milliseconds))
            switch expectation {
            case .device(let expected):
                success.append(Metrics.successAt1(ranked: ranked, expected: expected))
                mrr.append(Metrics.reciprocalRank(ranked: ranked, expected: expected))
                hit10.append(Metrics.recall(candidates: ranked, expected: expected, k: 10))
            case .set(let expected):
                let scores = Metrics.setScores(returned: ranked, expected: expected)
                precision.append(scores.precision)
                recall.append(scores.recall)
            case .graded(let gains):
                ndcg.append(Metrics.ndcg(ranked: ranked, gains: gains))
            }
        }

        static func mean(_ values: [Double]) -> String {
            values.isEmpty ? "—" : String(format: "%.2f", values.reduce(0, +) / Double(values.count))
        }

        static func ms(_ duration: Duration) -> String {
            String(format: "%.0f", milliseconds(duration))
        }

        var cells: [String] {
            ["\(count)", Self.mean(success), Self.mean(mrr), Self.mean(hit10), Self.mean(ndcg), Self.mean(precision),
             Self.mean(recall), String(format: "%.2f", count == 0 ? 0 : Double(zero) / Double(count)), "\(errors)",
             Self.ms(Metrics.percentile(latency, 50)), Self.ms(Metrics.percentile(latency, 95))]
        }
    }

    static func write(rows: [Row], queries: [GoldenQuery], snapshot: IndexSnapshot, header: [String]) {
        let columns = "| n | S@1 | MRR@10 | Hit@10 | nDCG@5 | Set P | Set R | Zero | Errors | p50 ms | p95 ms |"
        let rule = "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
        var lines = ["# Spotlight comparison", ""] + header.map { "- \($0)" } + ["", "## All queries", "",
                                                                                  "| System " + columns, rule]
        for system in System.allCases {
            var total = Scores()
            for (row, query) in zip(rows, queries) {
                if let outcome = row.results[system.rawValue] { total.add(outcome, query.expectation) }
            }
            guard total.count > 0 else { continue }
            lines.append("| \(system.rawValue) | " + total.cells.joined(separator: " | ") + " |")
        }
        for category in GoldenCategory.allCases {
            let pairs = zip(rows, queries).filter { $0.1.category == category }
            guard !pairs.isEmpty else { continue }
            lines += ["", "## \(category.rawValue)", "", "| System " + columns, rule]
            for system in System.allCases {
                var scores = Scores()
                for (row, query) in pairs {
                    if let outcome = row.results[system.rawValue] { scores.add(outcome, query.expectation) }
                }
                guard scores.count > 0 else { continue }
                lines.append("| \(system.rawValue) | " + scores.cells.joined(separator: " | ") + " |")
            }
        }
        let directory = URL.documentsDirectory
        try? lines.joined(separator: "\n").write(to: directory.appending(path: "spotlight-comparison.md"),
                                                 atomically: true, encoding: .utf8)
        var named = rows
        for index in named.indices {
            for (key, outcome) in named[index].results {
                named[index].results[key]?.ids = outcome.ids.prefix(10).map { label(DeviceID($0), snapshot) }
                    + (outcome.ids.count > 10 ? ["… \(outcome.ids.count) in all"] : [])
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(named).write(to: directory.appending(path: "spotlight-comparison.json"), options: .atomic)
    }

    // MARK: Helpers

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    static func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Item identifiers in the order the tool returned them, without repeats.
final class FoundIdentifiers: Sendable {
    private let state = Mutex<[String]>([])

    var ids: [String] { state.withLock { $0 } }

    func append(_ identifiers: [String]) {
        state.withLock { list in
            for identifier in identifiers where !list.contains(identifier) { list.append(identifier) }
        }
    }
}

@MainActor
@Observable
final class ComparisonProgress {
    private(set) var lines: [String] = []

    func log(_ line: String) {
        lines.append(line)
        print("[compare] \(line)")
        try? lines.joined(separator: "\n").write(to: URL.documentsDirectory.appending(path: "spotlight-comparison.log"),
                                                 atomically: true, encoding: .utf8)
    }
}

/// Shown instead of the demo's tabs when the app is launched with `-compareSpotlight`.
struct SpotlightComparisonView: View {
    let services: AppSearchServices
    @State private var progress = ComparisonProgress()

    var body: some View {
        NavigationStack {
            List(Array(progress.lines.enumerated().reversed()), id: \.offset) { line in
                Text(line.element).font(.caption.monospaced())
            }
            .navigationTitle("Spotlight comparison")
        }
        .task { await SpotlightComparison.run(services: services, progress: progress) }
    }
}

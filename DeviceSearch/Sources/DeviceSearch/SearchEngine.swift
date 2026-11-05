import Foundation
import SearchCore
import SearchIndex
import SearchRanking

/// What the UI and system surfaces depend on (the MVVM-C seam). `SearchEngine` is the real implementation;
/// view-model tests use a fake.
public protocol DeviceSearching: Sendable {
    /// Progressive results: instant, then hybrid, then refined or fallback. Dropping the stream cancels the search.
    func search(_ text: String, mode: SearchMode, options: SearchOptions) -> AsyncStream<SearchSnapshot>
    func recordSelection(of result: SearchResult, at position: Int, in snapshot: SearchSnapshot) async
    /// Called when the search field gains focus: prepares the model so the first refined search is fast.
    func prewarm() async
    /// The user stopped typing for a moment or submitted (reformulation detection).
    func searchSettled(_ text: String) async
}

/// Runs searches against the current immutable `IndexSnapshot` (design doc §4, §10).
///
/// Phases per search:
/// 1. Instant: parse, lexical retrievers, personal list, fusion, zero-result steps 1–2.
/// 2. Hybrid: after 120 ms idle while typing (immediately on submit), add meaning lists and re-fuse;
///    on submit, ladder step 4 (one rewrite) when still empty.
/// 3. Refined: submitted searches only; the gate decides; the refiner runs under a 2 s deadline;
///    any failure yields a fallback snapshot with the hybrid order. With the streaming flag on, a partial
///    refined snapshot (`isRefining == true`) may come first.
public actor SearchEngine: DeviceSearching, VectorUpdateSink {
    public nonisolated let homeID: HomeID
    public nonisolated let config: SearchConfig
    private var snapshot: IndexSnapshot
    private let pipeline: SearchPipeline
    private let flags: any FeatureFlagProviding
    private let telemetry: any SearchTelemetry
    private let meaning: (any MeaningRetrieval)?
    private let refiner: (any ResultRefining)?
    private let rewriter: (any QueryRewriting)?
    private let personal: (any PersonalSignals)?
    private var observers: [UUID: AsyncStream<IndexSnapshot>.Continuation] = [:]
    private var rebuildHandler: (@Sendable () async -> Void)?

    public init(snapshot: IndexSnapshot,
                config: SearchConfig = .default,
                flags: any FeatureFlagProviding = FeatureFlagStore(),
                telemetry: any SearchTelemetry = NoopTelemetry(),
                meaning: (any MeaningRetrieval)? = nil,
                refiner: (any ResultRefining)? = nil,
                rewriter: (any QueryRewriting)? = nil,
                personal: (any PersonalSignals)? = nil) {
        self.homeID = snapshot.homeID
        self.config = config.validated()
        self.snapshot = snapshot
        self.pipeline = SearchPipeline(config: config)
        self.flags = flags
        self.telemetry = telemetry
        self.meaning = meaning
        self.refiner = refiner
        self.rewriter = rewriter
        self.personal = personal
    }

    public var currentSnapshot: IndexSnapshot { snapshot }

    // MARK: Search

    public nonisolated func search(_ text: String, mode: SearchMode,
                                   options: SearchOptions = .standard) -> AsyncStream<SearchSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: SearchSnapshot.self, bufferingPolicy: .bufferingNewest(8))
        let task = Task { await self.run(text, mode: mode, options: options, continuation: continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Collects a search's snapshots (tests, evaluation, system surfaces).
    public nonisolated func searchAll(_ text: String, mode: SearchMode,
                                      options: SearchOptions = .standard) async -> [SearchSnapshot] {
        var phases: [SearchSnapshot] = []
        for await phase in search(text, mode: mode, options: options) { phases.append(phase) }
        return phases
    }

    private func run(_ text: String, mode: SearchMode, options: SearchOptions,
                     continuation: AsyncStream<SearchSnapshot>.Continuation) async {
        defer { continuation.finish() }
        let snapshot = self.snapshot
        let flags = self.flags.currentFlags()
        let clock = ContinuousClock()
        let start = clock.now
        var diagnostics = SearchDiagnostics()
        diagnostics.snapshotGeneration = snapshot.generation

        var parsed = pipeline.parse(text, mode: mode, options: options, in: snapshot)
        diagnostics.parseDuration = clock.now - start
        if parsed.isEmpty {
            continuation.yield(SearchSnapshot(phase: .instant, query: parsed,
                                              results: pipeline.presenter.emptyState(snapshot: snapshot),
                                              originalQuery: text, diagnostics: diagnostics))
            return
        }

        // Phase 1: instant.
        let retrieveStart = clock.now
        var lists = pipeline.lexicalLists(parsed, in: snapshot)
        var context = PresentationContext()
        if flags.personalizationEnabled, let personal,
           let personalList = await personal.personalList(for: parsed, pool: SearchPipeline.pool(lists),
                                                          in: snapshot, config: config) {
            lists.append(personalList.list)
            context.personalReasons = personalList.reasons
        }
        diagnostics.retrieveDuration = clock.now - retrieveStart
        let fuseStart = clock.now
        var (query, fusion) = pipeline.fuse(lists, query: parsed, in: snapshot)
        var ladder: [RelaxedFilter] = []

        // Zero-result ladder step 2: raise typo tolerance once.
        if fusion.candidates.isEmpty && options.allowCorrections && options.typoBudgetBoost == 0 {
            var boosted = options
            boosted.typoBudgetBoost = config.typoBudgetBoost
            let retry = pipeline.parse(text, mode: mode, options: boosted, in: snapshot)
            let retryLists = pipeline.lexicalLists(retry, in: snapshot)
            let retried = pipeline.fuse(retryLists, query: retry, in: snapshot)
            if !retried.fusion.candidates.isEmpty {
                parsed = retry
                lists = retryLists
                (query, fusion) = retried
                ladder.append(.spelling)
            }
        }
        diagnostics.fuseDuration = clock.now - fuseStart
        let instantDuration = clock.now - start

        let meaningEnabled = options.includeMeaning && flags.semanticEnabled && meaning != nil
        var gate: GateDecision?
        if !meaningEnabled { gate = await decideGate(query, fusion, mode: mode, options: options, flags: flags) }
        diagnostics.gate = gate
        var current = makeSnapshot(.instant, query: query, fusion: fusion, ladder: ladder, context: context,
                                   text: text, options: options, refining: gate?.outcome == .rerank,
                                   snapshot: snapshot, diagnostics: diagnostics)
        continuation.yield(current)
        if Task.isCancelled { return }

        // Phase 2: hybrid.
        var hybridDuration: Duration?
        var rewrittenText: String?
        if meaningEnabled, let meaning {
            if mode == .typing {
                do { try await Task.sleep(for: config.semanticIdleDelay) } catch { return }
            }
            if Task.isCancelled { return }
            let meaningStart = clock.now
            if let output = await meaning.meaningLists(for: parsed, in: snapshot, config: config) {
                let wasEmpty = fusion.candidates.isEmpty
                context.meaningLabel = output.label
                // Once concept routing has named device types, a descriptive query's meaning words stop counting as
                // names. A few weak semantic hits are not enough to give up a name match ("air" in "Air Purifier").
                let routed = output.lists.contains { $0.retriever == .concept && !$0.hits.isEmpty }
                if routed, let marked = pipeline.parser.describingNeeds(parsed, in: snapshot) {
                    parsed = marked
                    lists = pipeline.lexicalLists(marked, in: snapshot) + lists.filter { !$0.retriever.isLexical }
                }
                lists += output.lists
                (query, fusion) = pipeline.fuse(lists, query: parsed, in: snapshot)
                if wasEmpty && !fusion.candidates.isEmpty { ladder.append(.meaningOnly) }
            }
            hybridDuration = clock.now - meaningStart
            diagnostics.meaningDuration = hybridDuration
            if Task.isCancelled { return }
        }

        // Zero-result ladder step 4: one model rewrite, submitted searches only.
        if fusion.candidates.isEmpty, mode == .submitted, options.allowRefinement, flags.queryRewriteEnabled,
           let rewriter, let rewritten = try? await rewriter.rewrite(query, in: snapshot),
           !rewritten.isEmpty, rewritten != text {
            if Task.isCancelled { return }
            let retry = pipeline.parse(rewritten, mode: .submitted, options: SearchOptions(allowCorrections: false), in: snapshot)
            var retryLists = pipeline.lexicalLists(retry, in: snapshot)
            if meaningEnabled, let meaning, let output = await meaning.meaningLists(for: retry, in: snapshot, config: config) {
                retryLists += output.lists
                context.meaningLabel = output.label
            }
            let retried = pipeline.fuse(retryLists, query: retry, in: snapshot)
            if !retried.fusion.candidates.isEmpty {
                (query, fusion) = retried
                ladder.append(.rewrite)
                rewrittenText = rewritten
            }
        }

        if meaningEnabled || rewrittenText != nil {
            gate = await decideGate(query, fusion, mode: mode, options: options, flags: flags)
            diagnostics.gate = gate
            current = makeSnapshot(.hybrid, query: query, fusion: fusion, ladder: ladder, context: context, text: text,
                                   options: options, refining: gate?.outcome == .rerank, snapshot: snapshot,
                                   diagnostics: diagnostics, rewrittenText: rewrittenText)
            continuation.yield(current)
            if Task.isCancelled { return }
        }

        // Phase 3: refined or fallback.
        guard let decision = gate, decision.outcome != .skip else {
            record(current, instant: instantDuration, hybrid: hybridDuration)
            return
        }
        guard decision.outcome == .rerank, let refiner else {
            if refiner != nil {
                current.phase = .fallback
                current.isRefining = false
                continuation.yield(current)
            }
            record(current, instant: instantDuration, hybrid: hybridDuration)
            return
        }

        let request = RefinementRequest(query: query, candidates: fusion.top(config.candidateCount),
                                        snapshot: snapshot, context: context, config: config)
        let refineStart = clock.now
        var outcome: RerankOutcome = .refined
        do {
            // Streaming add-on (L08): validated top rows lock in before the rest of the answer arrives.
            let streaming = flags.streamingRerankEnabled
            let partialBase = current
            let refined = try await withDeadline(config.rerankDeadline) {
                guard streaming else { return try await refiner.refine(request) }
                return try await refiner.refine(request) { rows in
                    guard !Task.isCancelled, !rows.isEmpty else { return }
                    var partial = partialBase
                    partial.phase = .refined
                    partial.results = rows
                    partial.isRefining = true
                    continuation.yield(partial)
                }
            }
            if Task.isCancelled { return }
            current.diagnostics.refineDuration = clock.now - refineStart
            current.diagnostics.validatorInterventions = refined.interventions
            current.phase = .refined
            current.results = refined.results
            current.isRefining = false
            current.command = ResultPresenter.command(for: query, results: refined.results)
            continuation.yield(current)
            telemetry.record(.rerank(RerankMetrics(outcome: .refined, latency: clock.now - refineStart,
                                                   interventions: refined.interventions,
                                                   kendallTau: refined.kendallTau)))
        } catch is CancellationError {
            telemetry.record(.rerank(RerankMetrics(outcome: .cancelled, latency: clock.now - refineStart)))
            return
        } catch {
            if Task.isCancelled { return }
            if error is DeadlineExceeded {
                outcome = .timeout
            } else if let failure = error as? RefinementFailure {
                outcome = failure.outcome
            } else {
                outcome = .failed
            }
            current.phase = .fallback
            current.isRefining = false
            continuation.yield(current)
            telemetry.record(.rerank(RerankMetrics(outcome: outcome, latency: clock.now - refineStart)))
        }
        record(current, instant: instantDuration, hybrid: hybridDuration)
        Task { await refiner.prewarm() }
    }

    private func decideGate(_ query: ParsedQuery, _ fusion: FusionResult, mode: SearchMode, options: SearchOptions,
                            flags: SearchFeatureFlags) async -> GateDecision? {
        guard mode == .submitted else { return nil }
        var available = false
        if options.allowRefinement, flags.rerankEnabled, let refiner { available = await refiner.isAvailable() }
        return pipeline.gate.decide(query: query, fusion: fusion, modelAvailable: available)
    }

    private func makeSnapshot(_ phase: SearchPhase, query: ParsedQuery, fusion: FusionResult, ladder: [RelaxedFilter],
                              context: PresentationContext, text: String, options: SearchOptions, refining: Bool,
                              snapshot: IndexSnapshot, diagnostics: SearchDiagnostics,
                              rewrittenText: String? = nil) -> SearchSnapshot {
        var diagnostics = diagnostics
        diagnostics.candidateCount = fusion.candidates.count
        diagnostics.topCandidates = fusion.top(20).map(\.document)
        var results = pipeline.presenter.fusedResults(query: query, fusion: fusion, snapshot: snapshot, context: context)
        var message: String?
        if results.isEmpty {
            // Zero-result ladder step 5: favorites and recents under a message.
            results = pipeline.presenter.emptyState(snapshot: snapshot)
            message = "No devices match “\(text.trimmingCharacters(in: .whitespacesAndNewlines))”"
        }
        let corrected: String?
        if let rewrittenText {
            corrected = rewrittenText
        } else {
            corrected = options.allowCorrections && query.hasCorrections ? query.correctedText : nil
        }
        return SearchSnapshot(
            phase: phase, query: query, results: results,
            setSummary: query.intent.isSet && message == nil ? ResultPresenter.setSummary(for: results) : nil,
            correctedQuery: corrected, originalQuery: text, relaxed: fusion.relaxed + ladder,
            command: message == nil ? ResultPresenter.command(for: query, results: results) : nil,
            isRefining: refining && message == nil, noMatchesMessage: message, diagnostics: diagnostics)
    }

    private func record(_ snapshot: SearchSnapshot, instant: Duration, hybrid: Duration?) {
        telemetry.record(.searchCompleted(SearchMetrics(
            intent: snapshot.query.intent, mode: snapshot.query.mode, phase: snapshot.phase,
            resultCount: snapshot.noMatchesMessage == nil ? snapshot.results.count : 0,
            gate: snapshot.diagnostics.gate?.outcome, instantDuration: instant, hybridDuration: hybrid)))
    }

    // MARK: Signals from the UI

    public func prewarm() async {
        guard flags.currentFlags().rerankEnabled, let refiner else { return }
        await refiner.prewarm()
    }

    public func recordSelection(of result: SearchResult, at position: Int, in snapshot: SearchSnapshot) async {
        telemetry.record(.selection(position: position, section: result.section))
        guard flags.currentFlags().personalizationEnabled, let personal else { return }
        let lexical = result.evidence.contains { $0.isLexical }
        let change = await personal.recordSelection(SelectionRecord(
            queryKey: snapshot.query.cleanKey, device: result.id, position: position,
            hadLexicalEvidence: lexical, date: Date()))
        await apply(change, from: personal)
    }

    public func searchSettled(_ text: String) async {
        guard flags.currentFlags().personalizationEnabled, let personal else { return }
        await personal.recordSettledQuery(text, at: Date())
    }

    /// The device was opened or controlled from anywhere in the app.
    public func recordUsage(of device: DeviceID) async {
        guard flags.currentFlags().personalizationEnabled, let personal else { return }
        let change = await personal.recordUsage(of: device, at: Date())
        await apply(change, from: personal)
    }

    /// Called by `HomeSearch.make`: how the engine asks the data plane for a rebuild (a nickname was learned).
    public func onRebuildNeeded(_ handler: @escaping @Sendable () async -> Void) {
        rebuildHandler = handler
    }

    private func apply(_ change: PersonalChange, from personal: any PersonalSignals) async {
        if change.contains(.priors), let priors = await personal.indexInputs(for: allDevices()).priors {
            applyPriors(priors)
        }
        if change.contains(.aliases) { await rebuildHandler?() }
    }

    // MARK: Snapshot management (data plane)

    /// Installs a newer snapshot. Queries in flight keep the snapshot they started with.
    public func swap(_ newSnapshot: IndexSnapshot) async {
        guard newSnapshot.generation >= snapshot.generation else { return }
        snapshot = newSnapshot
        publish()
        if flags.currentFlags().semanticEnabled, let meaning {
            await meaning.snapshotDidChange(newSnapshot, sink: self)
        }
    }

    /// Status fast path (design doc §11): two bitsets updated in place, no rebuild.
    public func applyStatus(_ status: DeviceStatus?, for device: DeviceID) {
        guard let updated = snapshot.updatingStatus(status, for: device) else { return }
        snapshot = updated
    }

    public func applyPriors(_ priors: [DeviceID: Double]) {
        snapshot = snapshot.updatingPriors(priors)
    }

    public func applyVectors(_ vectors: VectorStore, concepts: ConceptVectors, generation: UInt64) async {
        guard generation == snapshot.generation, vectors.capacity == snapshot.count else { return }
        snapshot = snapshot.withVectors(vectors, concepts: concepts)
    }

    /// Emits the current snapshot, then every new one (Spotlight indexing, debug screens).
    public func snapshotUpdates() -> AsyncStream<IndexSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: IndexSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func publish() {
        for continuation in observers.values { continuation.yield(snapshot) }
    }

    // MARK: System surfaces (fast path, no model)

    /// Lexical results only, for Spotlight, Siri and Shortcuts entity queries.
    public func topResults(for text: String, limit: Int) -> [SearchResult] {
        let query = pipeline.parse(text, mode: .submitted, options: .fastPath, in: snapshot)
        guard !query.isEmpty else { return [] }
        let lists = pipeline.lexicalLists(query, in: snapshot)
        let fused = pipeline.fuse(lists, query: query, in: snapshot)
        return Array(pipeline.presenter.fusedResults(query: fused.query, fusion: fused.fusion, snapshot: snapshot)
            .prefix(limit))
    }

    public func devices(withIDs ids: [DeviceID]) -> [DeviceRecord] {
        ids.compactMap { snapshot.document(for: $0)?.device }
    }

    public func allDevices() -> [DeviceRecord] { snapshot.documents.map(\.device) }

    public func favoritesAndRecents(limit: Int) -> [SearchResult] {
        Array(pipeline.presenter.emptyState(snapshot: snapshot).prefix(limit))
    }
}

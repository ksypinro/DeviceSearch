import Foundation
import Observation
import SearchCore
import DeviceSearch

/// The UI state machine (design doc §10, S04). Every edit returns to `.instant` and cancels in-flight work.
public enum SearchUIState: String, Equatable, Sendable {
    case idle, instant, hybrid, refining, refined, fallback
}

/// A VoiceOver announcement. The id changes every time, so repeating the same text is announced again.
public struct SearchAnnouncement: Equatable, Sendable {
    public let id: Int
    public let text: String
}

/// Results grouped for display (design doc §9, P03).
public struct ResultGroup: Identifiable, Equatable, Sendable {
    public var section: ResultSection
    public var results: [SearchResult]
    public var id: ResultSection { section }
}

/// The search screen's view model (design doc §13 M03).
///
/// - Typing searches run on every edit; the previous search is cancelled (S01). Submitting runs the gated
///   model path (S02).
/// - Snapshots of the same search that arrive while the list is touched are held and applied on release (P02).
/// - VoiceOver hears the count after typing pauses for 1 s or on submit, never per keystroke, and
///   "Results refined" when the refined phase lands (P06, D11).
/// - A query settles after 1 s without typing or on submit (D10) and is reported for reformulation detection.
@MainActor
@Observable
public final class SearchViewModel {
    /// Bound to the search field.
    public var text: String = "" {
        didSet { if text != oldValue { textDidChange() } }
    }
    /// The snapshot on screen.
    public private(set) var snapshot: SearchSnapshot?
    public private(set) var state: SearchUIState = .idle
    public private(set) var announcement: SearchAnnouncement?
    public private(set) var isListening = false
    /// True while a newer phase waits for the finger to lift.
    public private(set) var hasHeldUpdate = false
    /// Set by the view while the list is touched or scrolling.
    public var isInteracting = false {
        didSet { if oldValue && !isInteracting { applyHeldSnapshot() } }
    }

    @ObservationIgnored private let engine: any DeviceSearching
    @ObservationIgnored private weak var coordinator: (any SearchCoordinating)?
    @ObservationIgnored private let voice: (any VoiceTranscribing)?
    @ObservationIgnored private let flags: any FeatureFlagProviding
    @ObservationIgnored private let settleDelay: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var voiceTask: Task<Void, Never>?
    @ObservationIgnored private var held: SearchSnapshot?
    @ObservationIgnored private var announcementCount = 0
    @ObservationIgnored private var mode: SearchMode = .typing

    /// - Parameter coordinator: held weakly (the usual coordinator ownership), so the caller must keep it alive,
    ///   for example in the screen's `@State`. A coordinator created inline is freed at once, and taps on
    ///   results and commands then do nothing.
    public init(engine: any DeviceSearching, coordinator: (any SearchCoordinating)? = nil,
                voice: (any VoiceTranscribing)? = nil, flags: any FeatureFlagProviding = FeatureFlagStore(),
                settleDelay: Duration = .seconds(1),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.engine = engine
        self.coordinator = coordinator
        self.voice = voice
        self.flags = flags
        self.settleDelay = settleDelay
        self.sleep = sleep
    }

    public func setCoordinator(_ coordinator: any SearchCoordinating) {
        self.coordinator = coordinator
    }

    // MARK: Input

    /// Shows favorites and frequent devices before anything is typed (P09).
    public func start() {
        run(mode: .typing, options: .standard)
    }

    /// Return key or the search button: the full path, model included (S02).
    public func submit() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        settleTask?.cancel()
        run(mode: .submitted, options: .standard)
        let engine = self.engine
        let query = text
        Task { await engine.searchSettled(query) }
    }

    /// "Search for Y instead": runs the original words without corrections (P05).
    public func searchOriginalInstead() {
        settleTask?.cancel()
        run(mode: .submitted, options: SearchOptions(allowCorrections: false))
    }

    /// The search field gained or lost focus. Focus prewarms the model (L05).
    public func focusChanged(_ focused: Bool) {
        guard focused else { return }
        let engine = self.engine
        Task { await engine.prewarm() }
    }

    public func clear() {
        text = ""
    }

    // MARK: Actions

    public func select(_ result: SearchResult) {
        guard let snapshot, let index = snapshot.results.firstIndex(where: { $0.id == result.id }) else { return }
        let engine = self.engine
        Task { await engine.recordSelection(of: result, at: index + 1, in: snapshot) }
        coordinator?.openDevice(result.id)
    }

    public func runCommand() {
        guard let command = snapshot?.command else { return }
        coordinator?.perform(command)
    }

    // MARK: Voice (C20)

    public var showsVoiceButton: Bool { voice != nil && flags.currentFlags().voiceEnabled }

    public func toggleVoice() {
        if isListening { stopVoice() } else { startVoice() }
    }

    /// Partial transcripts update the field like typing; the final transcript submits.
    public func startVoice() {
        guard let voice, !isListening else { return }
        isListening = true
        voiceTask = Task { [weak self] in
            do {
                for try await transcript in try await voice.transcripts() {
                    guard let self, !Task.isCancelled else { return }
                    self.text = transcript.text
                    if transcript.isFinal {
                        self.submit()
                        break
                    }
                }
            } catch {
                // Voice is optional: an error ends listening and leaves the field as it is.
            }
            self?.isListening = false
        }
    }

    public func stopVoice() {
        voiceTask?.cancel()
        voiceTask = nil
        isListening = false
        if let voice { Task { await voice.stop() } }
    }

    // MARK: Derived presentation

    public var groups: [ResultGroup] {
        guard let snapshot else { return [] }
        var groups: [ResultGroup] = []
        for result in snapshot.results {
            if let last = groups.indices.last, groups[last].section == result.section {
                groups[last].results.append(result)
            } else if let existing = groups.firstIndex(where: { $0.section == result.section }) {
                groups[existing].results.append(result)
            } else {
                groups.append(ResultGroup(section: result.section, results: [result]))
            }
        }
        return groups
    }

    /// "Showing results for X" and the original words (P05).
    public var correction: (showing: String, original: String)? {
        guard let snapshot, let corrected = snapshot.correctedQuery else { return nil }
        return (corrected, snapshot.originalQuery.trimmingCharacters(in: .whitespaces))
    }

    /// Why the list is broader than the query (zero-result ladder, P07).
    public var relaxationNote: String? {
        guard let relaxed = snapshot?.relaxed, snapshot?.noMatchesMessage == nil else { return nil }
        let filters = relaxed.compactMap { filter -> String? in
            switch filter {
            case .status: return "status"
            case .room: return "room"
            case .brand: return "brand"
            case .type: return "type"
            case .exclusions: return "exclusion"
            case .spelling, .meaningOnly, .rewrite: return nil
            }
        }
        if !filters.isEmpty {
            return "No exact matches. Showing results without the \(filters.joined(separator: ", ")) filter."
        }
        if relaxed.contains(.meaningOnly) { return "No device names match. Showing devices that fit the meaning." }
        return nil
    }

    public var countText: String {
        guard let snapshot else { return "" }
        if snapshot.noMatchesMessage != nil { return "No results" }
        if let summary = snapshot.setSummary { return summary.count == 1 ? "1 device" : "\(summary.count) devices" }
        switch snapshot.results.count {
        case 0: return "No results"
        case 1: return "1 result"
        case let count: return "\(count) results"
        }
    }

    // MARK: Internals

    private func textDidChange() {
        settleTask?.cancel()
        run(mode: .typing, options: .standard)
    }

    private func run(mode: SearchMode, options: SearchOptions) {
        searchTask?.cancel()
        held = nil
        hasHeldUpdate = false
        self.mode = mode
        let stream = engine.search(text, mode: mode, options: options)
        searchTask = Task { [weak self] in
            for await snapshot in stream {
                guard let self, !Task.isCancelled else { return }
                self.receive(snapshot, mode: mode)
            }
        }
    }

    private func receive(_ incoming: SearchSnapshot, mode: SearchMode) {
        // P02: a later phase of the same search waits while the list is touched.
        if isInteracting, incoming.phase != .instant, let current = snapshot,
           current.originalQuery == incoming.originalQuery {
            held = incoming
            hasHeldUpdate = true
            return
        }
        apply(incoming, mode: mode)
    }

    private func applyHeldSnapshot() {
        guard let held else { return }
        self.held = nil
        hasHeldUpdate = false
        apply(held, mode: mode)
    }

    private func apply(_ incoming: SearchSnapshot, mode: SearchMode) {
        let wasRefining = state == .refining
        snapshot = incoming
        state = Self.state(for: incoming)
        if incoming.phase == .instant {
            if mode == .submitted {
                announce(countText)
            } else if !incoming.query.isEmpty {
                scheduleSettle(for: incoming.originalQuery)
            }
        }
        if incoming.phase == .refined && !incoming.isRefining && (wasRefining || mode == .submitted) {
            announce("Results refined")
        }
    }

    /// After 1 s without typing: report the settled query and announce the count (D10, D11).
    private func scheduleSettle(for query: String) {
        settleTask?.cancel()
        let delay = settleDelay
        let sleep = self.sleep
        let engine = self.engine
        settleTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled, self.text == query else { return }
            self.announce(self.countText)
            await engine.searchSettled(query)
        }
    }

    private func announce(_ text: String) {
        guard !text.isEmpty else { return }
        announcementCount += 1
        announcement = SearchAnnouncement(id: announcementCount, text: text)
    }

    static func state(for snapshot: SearchSnapshot) -> SearchUIState {
        if snapshot.query.isEmpty { return .idle }
        switch snapshot.phase {
        case .instant: return snapshot.isRefining ? .refining : .instant
        case .hybrid: return snapshot.isRefining ? .refining : .hybrid
        case .refined: return snapshot.isRefining ? .refining : .refined
        case .fallback: return .fallback
        }
    }
}

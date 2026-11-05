import Synchronization

/// Remote switches for every optional component (design doc §18). Read on every search, so flipping a flag
/// acts as a kill switch without an app restart.
public struct SearchFeatureFlags: Sendable, Equatable, Codable {
    /// Meaning signals: semantic and concept retrievers (milestone 2).
    public var semanticEnabled: Bool
    /// Foundation Models re-rank on submitted searches (milestone 3).
    public var rerankEnabled: Bool
    /// One model rewrite when nothing else matched (milestone 3).
    public var queryRewriteEnabled: Bool
    /// Streamed re-rank output (optional add-on).
    public var streamingRerankEnabled: Bool
    /// Personal retriever and learned priors (milestone 4).
    public var personalizationEnabled: Bool
    /// Nickname learning (milestone 4).
    public var nicknamesEnabled: Bool
    /// Spotlight donation of device entities (milestone 4).
    public var spotlightEnabled: Bool
    /// Microphone button (milestone 4).
    public var voiceEnabled: Bool

    public init(semanticEnabled: Bool = true, rerankEnabled: Bool = true, queryRewriteEnabled: Bool = true,
                streamingRerankEnabled: Bool = false, personalizationEnabled: Bool = true,
                nicknamesEnabled: Bool = true, spotlightEnabled: Bool = true, voiceEnabled: Bool = true) {
        self.semanticEnabled = semanticEnabled
        self.rerankEnabled = rerankEnabled
        self.queryRewriteEnabled = queryRewriteEnabled
        self.streamingRerankEnabled = streamingRerankEnabled
        self.personalizationEnabled = personalizationEnabled
        self.nicknamesEnabled = nicknamesEnabled
        self.spotlightEnabled = spotlightEnabled
        self.voiceEnabled = voiceEnabled
    }

    /// Everything on except streaming.
    public static let allOn = SearchFeatureFlags()
    /// Lexical search only (milestone 1 behaviour).
    public static let lexicalOnly = SearchFeatureFlags(
        semanticEnabled: false, rerankEnabled: false, queryRewriteEnabled: false, streamingRerankEnabled: false,
        personalizationEnabled: false, nicknamesEnabled: false, spotlightEnabled: false, voiceEnabled: false)
}

/// Supplies the current flags. Implement it over your remote-config system.
public protocol FeatureFlagProviding: Sendable {
    func currentFlags() -> SearchFeatureFlags
}

/// A thread-safe, settable flag store. Use it directly or as the bridge from remote config.
public final class FeatureFlagStore: FeatureFlagProviding {
    private let state: Mutex<SearchFeatureFlags>

    public init(_ flags: SearchFeatureFlags = .allOn) {
        state = Mutex(flags)
    }

    public func currentFlags() -> SearchFeatureFlags { state.withLock { $0 } }

    public func update(_ change: (inout SearchFeatureFlags) -> Void) {
        state.withLock { change(&$0) }
    }
}

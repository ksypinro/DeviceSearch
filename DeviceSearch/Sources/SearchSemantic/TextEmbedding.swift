import SearchCore

/// Turns text into a vector (design doc §6, R11). Implementations: `NLContextualEmbedder` (Apple, default),
/// `LexiconEmbedding` (deterministic fallback and test double). A Core ML encoder can be added later.
public protocol TextEmbedding: Sendable {
    var dimension: Int { get }
    /// Part of the cache key: vectors from different models never mix.
    var modelVersion: String { get }
    /// Contextual embeddings share a dominant direction; mean-centering removes it (decision D06).
    var centersVectors: Bool { get }
    /// Downloads assets and loads the model. Safe to call more than once.
    func prepare() async throws
    /// False when the text's language is not supported (meaning signals are then skipped).
    func supports(_ text: String) -> Bool
    /// A raw vector (not centered). Throws when the model is unavailable.
    func embed(_ text: String) async throws -> [Float]
}

public enum EmbeddingError: Error, Equatable {
    case unavailable
    case unsupportedLanguage
    case emptyText
}

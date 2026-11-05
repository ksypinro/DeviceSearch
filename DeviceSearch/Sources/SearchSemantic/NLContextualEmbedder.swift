#if canImport(NaturalLanguage)
import Foundation
import NaturalLanguage
import SearchCore

/// Sentence vectors from Apple's `NLContextualEmbedding` (design doc §6, R11): token vectors are mean-pooled
/// into one vector per text. One instance serves one script/language model; create one per language you support.
///
/// `NLContextualEmbedding` is not `Sendable`, so it lives inside this actor.
public actor NLContextualEmbedder: TextEmbedding {
    private let model: NLContextualEmbedding
    private var loaded = false
    public nonisolated let dimension: Int
    public nonisolated let modelVersion: String
    public nonisolated let languages: Set<NLLanguage>

    /// Returns nil when the system has no contextual embedding model for the language.
    public init?(language: NLLanguage = .english) {
        guard let model = NLContextualEmbedding(language: language) else { return nil }
        self.model = model
        self.dimension = model.dimension
        self.modelVersion = "nl-\(model.modelIdentifier)-\(model.revision)"
        self.languages = Set(model.languages)
    }

    public nonisolated var centersVectors: Bool { true }

    /// Downloads assets if needed, then loads the model. Call at app launch or when search opens.
    public func prepare() async throws {
        guard !loaded else { return }
        if !model.hasAvailableAssets {
            let result = try await model.requestAssets()
            guard result == .available else { throw EmbeddingError.unavailable }
        }
        try model.load()
        loaded = true
    }

    /// Supported when the dominant language is one of the model's languages (or cannot be detected).
    public nonisolated func supports(_ text: String) -> Bool {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return true }
        return languages.contains(language)
    }

    public func embed(_ text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmbeddingError.emptyText }
        try await prepare()
        let result = try model.embeddingResult(for: trimmed, language: nil)
        var sum = [Double](repeating: 0, count: dimension)
        var count = 0.0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            for index in 0..<min(vector.count, sum.count) { sum[index] += vector[index] }
            count += 1
            return true
        }
        guard count > 0 else { throw EmbeddingError.unavailable }
        return sum.map { Float($0 / count) }
    }
}
#endif

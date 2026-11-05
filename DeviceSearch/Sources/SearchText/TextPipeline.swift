/// Segment → normalize → split → stem. One value is shared by the index builder and the query parser,
/// which guarantees index-time and query-time text processing are identical (design doc §5).
public struct TextPipeline: Sendable {
    public var segmenter: any WordSegmenting
    public var normalizer: TextNormalizer
    public var stemmer: Stemmer

    public init(segmenter: any WordSegmenting = PassthroughSegmenter(),
                normalizer: TextNormalizer = TextNormalizer(),
                stemmer: Stemmer = Stemmer()) {
        self.segmenter = segmenter
        self.normalizer = normalizer
        self.stemmer = stemmer
    }

    /// Normalized, unstemmed tokens.
    public func normalizedTokens(_ text: String, splitCamelCase: Bool = true) -> [String] {
        normalizer.tokens(segmenter.segment(text), splitCamelCase: splitCamelCase)
    }

    /// Normalized, stemmed tokens. This is what the index stores and what queries match against.
    public func terms(_ text: String, splitCamelCase: Bool = true) -> [String] {
        normalizedTokens(text, splitCamelCase: splitCamelCase).map(stemmer.stem)
    }

    /// Stemmed tokens joined by single spaces. Used as phrase and exact-name keys.
    public func key(_ text: String, splitCamelCase: Bool = true) -> String {
        terms(text, splitCamelCase: splitCamelCase).joined(separator: " ")
    }
}

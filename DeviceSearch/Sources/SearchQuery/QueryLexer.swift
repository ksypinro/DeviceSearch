import SearchCore
import SearchKnowledge
import SearchText

/// Normalizes the raw query and detects a leading command verb (design doc §5).
///
/// - "turn off hallway lights" → action "turn off", tokens ["hallway", "lights"]
/// - "turn hallway lights off" → action "turn off", tokens ["hallway", "lights"]
/// - "switch bedroom" → no action ("switch" is also a device type and needs "on", "the", "all", … after it)
public struct QueryLexer: Sendable {
    public struct Output: Sendable, Equatable {
        public var normalized: String
        public var action: String?
        /// Normalized, unstemmed tokens after the action words.
        public var tokens: [String]
    }

    public init() {}

    public func lex(_ raw: String, pipeline: TextPipeline, lexicon: Lexicon) -> Output {
        let normalized = pipeline.normalizer.normalize(pipeline.segmenter.segment(raw))
        var tokens = normalized.isEmpty ? [] : normalized.split(separator: " ").map(String.init)
        var action: String?
        let verbs = Set(lexicon.actionVerbs)
        let strictVerbs = Set(lexicon.strictActionVerbs)
        let particles = Set(lexicon.actionParticles)
        let trailingParticles = particles.intersection(["on", "off"])
        if tokens.count >= 2, verbs.contains(tokens[0]) || strictVerbs.contains(tokens[0]) {
            let isStrict = strictVerbs.contains(tokens[0])
            if !isStrict || lexicon.strictFollowers.contains(tokens[1]) {
                var verb = tokens[0]
                var skip = 1
                if particles.contains(tokens[1]) {
                    verb += " " + tokens[1]
                    skip = 2
                } else if tokens.count > 2, let last = tokens.last, trailingParticles.contains(last) {
                    verb += " " + last
                    tokens.removeLast()
                }
                action = verb
                tokens = Array(tokens.dropFirst(skip))
            }
        }
        return Output(normalized: normalized, action: action, tokens: tokens)
    }
}

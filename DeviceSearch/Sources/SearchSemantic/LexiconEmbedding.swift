import SearchCore
import SearchIndex
import SearchKnowledge
import SearchText

/// A deterministic embedding over the knowledge base's concept dimensions ("cool", "light", "security", …).
///
/// Text is walked with the phrase dictionary: device types add their card's concept weights, rooms add
/// 0.4 × their concepts, and meaning words ("hot", "movie", "intruder") add their lexicon weights.
/// Used as the test double for meaning retrieval, as the fallback when contextual-embedding assets are missing,
/// and to label a query's meaning in reason chips ("Meaning: cooling").
public struct LexiconEmbedding: TextEmbedding {
    public let knowledge: KnowledgeBase
    public let pipeline: TextPipeline
    private let phrases: PhraseDictionary
    private let dimensions: [String]
    private let meaningWords: [String: [String: Double]]
    public let roomWeight: Double

    public init(knowledge: KnowledgeBase, pipeline: TextPipeline? = nil, roomWeight: Double = 0.4) {
        let pipeline = pipeline ?? knowledge.makePipeline()
        self.knowledge = knowledge
        self.pipeline = pipeline
        self.phrases = PhraseDictionary(knowledge: knowledge, pipeline: pipeline)
        self.dimensions = knowledge.lexicon.conceptDimensions
        var words: [String: [String: Double]] = [:]
        for (word, weights) in knowledge.lexicon.meaningWords { words[pipeline.stemmer.stem(word)] = weights }
        self.meaningWords = words
        self.roomWeight = roomWeight
    }

    public var dimension: Int { dimensions.count }
    public var modelVersion: String { "lexicon-\(knowledge.version)" }
    public var centersVectors: Bool { false }

    public func prepare() async throws {}

    public func supports(_ text: String) -> Bool { true }

    public func embed(_ text: String) async throws -> [Float] { vector(for: text) }

    /// The unnormalized concept vector (all zeros when nothing in the text carries meaning).
    public func vector(for text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: dimensions.count)
        let terms = pipeline.terms(text)
        var index = 0
        while index < terms.count {
            if let match = phrases.longestMatch(in: terms, from: index),
               match.entries.contains(where: { $0.kind == .type || $0.kind == .room }) {
                for entry in match.entries {
                    if entry.kind == .type, let card = knowledge.typeCard(id: entry.id) {
                        add(card.concepts, weight: 1, to: &vector)
                    } else if entry.kind == .room, let room = knowledge.rooms.first(where: { $0.id == entry.id }) {
                        add(room.concepts, weight: roomWeight, to: &vector)
                    }
                }
                index += match.length
                continue
            }
            if let weights = meaningWords[terms[index]] { add(weights, weight: 1, to: &vector) }
            index += 1
        }
        return vector
    }

    /// Labels of the strongest dimensions (weight ≥ 0.3 of a unit vector), at most two: "cooling + air quality".
    public func label(for text: String) -> String? {
        guard let unit = VectorStore.normalized(vector(for: text)) else { return nil }
        let top = unit.enumerated()
            .filter { $0.element >= 0.3 }
            .sorted { $0.element > $1.element }
            .prefix(2)
            .map { knowledge.conceptLabel(dimensions[$0.offset]) }
        return top.isEmpty ? nil : top.joined(separator: " + ")
    }

    private func add(_ weights: [String: Double], weight: Double, to vector: inout [Float]) {
        for (dimension, value) in weights {
            if let position = dimensions.firstIndex(of: dimension) { vector[position] += Float(value * weight) }
        }
    }
}

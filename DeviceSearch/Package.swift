// swift-tools-version: 6.0
// DeviceSearch: hybrid on-device device search (lexical retrieval + meaning signals + gated LLM re-rank).
import PackageDescription

let package = Package(
    name: "DeviceSearch",
    defaultLocalization: "en",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "DeviceSearch", targets: ["DeviceSearch"]),
        .library(name: "SearchSemantic", targets: ["SearchSemantic"]),
        .library(name: "SearchRerank", targets: ["SearchRerank"]),
        .library(name: "SearchPersonalization", targets: ["SearchPersonalization"]),
        .library(name: "DeviceSearchUI", targets: ["DeviceSearchUI"]),
        .library(name: "SearchEvaluation", targets: ["SearchEvaluation"]),
    ],
    targets: [
        // Layer 0: shared value types, configuration, telemetry contract.
        .target(name: "SearchCore"),
        // Layer 1: text primitives (normalize, stem, typo distance, phonetic keys, trigrams).
        .target(name: "SearchText", dependencies: ["SearchCore"]),
        // Layer 1: knowledge base (device types, brands, rooms, lexicon) shipped as JSON resources.
        .target(name: "SearchKnowledge", dependencies: ["SearchCore", "SearchText"],
                resources: [.process("Resources")]),
        // Layer 2: the immutable index snapshot and its builder.
        .target(name: "SearchIndex", dependencies: ["SearchCore", "SearchText", "SearchKnowledge"]),
        // Layer 3: query understanding (S1, S2).
        .target(name: "SearchQuery", dependencies: ["SearchCore", "SearchText", "SearchKnowledge", "SearchIndex"]),
        // Layer 3: the lexical retrievers (S3).
        .target(name: "SearchRetrieval", dependencies: ["SearchCore", "SearchText", "SearchIndex"]),
        // Layer 4: fusion, gate, presentation (S4, S5, S8).
        .target(name: "SearchRanking", dependencies: ["SearchCore", "SearchText", "SearchKnowledge", "SearchIndex"]),
        // Layer 5: the engine, index sync and extension points.
        .target(name: "DeviceSearch", dependencies: [
            "SearchCore", "SearchText", "SearchKnowledge", "SearchIndex",
            "SearchQuery", "SearchRetrieval", "SearchRanking",
        ]),
        // Layer 6 plug-ins: meaning (M2), re-rank (M3), personalization (M4).
        .target(name: "SearchSemantic", dependencies: ["DeviceSearch"]),
        .target(name: "SearchRerank", dependencies: ["DeviceSearch"]),
        .target(name: "SearchPersonalization", dependencies: ["DeviceSearch"]),
        // SwiftUI layer.
        .target(name: "DeviceSearchUI", dependencies: ["DeviceSearch"]),
        // Fixtures shared by tests (synthetic homes, index helpers).
        .target(name: "SearchTestSupport", dependencies: [
            "SearchCore", "SearchText", "SearchKnowledge", "SearchIndex", "SearchQuery",
        ]),
        // Golden sets, metrics and the evaluation runner.
        .target(name: "SearchEvaluation", dependencies: ["DeviceSearch", "SearchTestSupport"],
                resources: [.process("Resources")]),

        .testTarget(name: "SearchCoreTests", dependencies: ["SearchCore"]),
        .testTarget(name: "SearchTextTests", dependencies: ["SearchText"]),
        .testTarget(name: "SearchKnowledgeTests", dependencies: ["SearchKnowledge"]),
        .testTarget(name: "SearchIndexTests", dependencies: ["SearchIndex", "SearchTestSupport"]),
        .testTarget(name: "SearchQueryTests", dependencies: ["SearchQuery", "SearchTestSupport"]),
        .testTarget(name: "SearchRetrievalTests", dependencies: ["SearchRetrieval", "SearchQuery", "SearchTestSupport"]),
        .testTarget(name: "SearchRankingTests", dependencies: [
            "SearchRanking", "SearchRetrieval", "SearchQuery", "SearchTestSupport",
        ]),
        .testTarget(name: "DeviceSearchTests", dependencies: ["DeviceSearch", "SearchTestSupport"]),
        .testTarget(name: "SearchSemanticTests", dependencies: ["SearchSemantic", "SearchTestSupport"]),
        .testTarget(name: "SearchRerankTests", dependencies: ["SearchRerank", "SearchTestSupport"]),
        .testTarget(name: "SearchPersonalizationTests", dependencies: ["SearchPersonalization", "SearchTestSupport"]),
        .testTarget(name: "DeviceSearchUITests", dependencies: ["DeviceSearchUI", "SearchTestSupport"]),
        .testTarget(name: "SearchEvaluationTests", dependencies: [
            "SearchEvaluation", "SearchSemantic", "SearchRerank", "SearchPersonalization",
        ]),
    ]
)

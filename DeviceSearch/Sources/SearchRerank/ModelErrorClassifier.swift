import SearchCore
import DeviceSearch

/// Maps any model error to a telemetry outcome (decision D19). Classification reads the error's case name and
/// description instead of matching `LanguageModelSession.GenerationError`, which iOS 27 deprecates in favour of
/// `LanguageModelError`, so the same code works with both SDKs. Every outcome falls back the same way.
public enum ModelErrorClassifier {
    public static func classify(_ error: any Error) -> RerankOutcome {
        if error is CancellationError { return .cancelled }
        if error is DeadlineExceeded { return .timeout }
        if let failure = error as? RefinementFailure { return failure.outcome }
        let caseName = Mirror(reflecting: error).children.first?.label ?? ""
        let text = (caseName + " " + String(reflecting: error)).lowercased()
        if text.contains("contextwindow") || text.contains("contextsize") || text.contains("exceededcontext") {
            return .contextWindow
        }
        if text.contains("guardrail") { return .guardrail }
        if text.contains("unsupportedlanguage") || text.contains("unsupportedlocale") { return .unsupportedLanguage }
        if text.contains("assetsunavailable") || text.contains("notready") || text.contains("unavailable") {
            return .unavailable
        }
        return .failed
    }
}

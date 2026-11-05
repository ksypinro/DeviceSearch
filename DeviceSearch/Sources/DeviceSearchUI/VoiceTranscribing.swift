/// A transcript from speech recognition.
public struct VoiceTranscript: Equatable, Sendable {
    public var text: String
    public var isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// Speech-to-text for the microphone button (design doc §3 C20, decision D08). Transcripts feed the same
/// pipeline as typing. `SpeechVoiceTranscriber` is the on-device implementation.
public protocol VoiceTranscribing: Sendable {
    /// Microphone and speech permission granted, and on-device recognition supported for the locale.
    func isAvailable() async -> Bool
    /// Starts listening. Partial transcripts arrive as they change; the last one is final.
    func transcripts() async throws -> AsyncThrowingStream<VoiceTranscript, any Error>
    func stop() async
}

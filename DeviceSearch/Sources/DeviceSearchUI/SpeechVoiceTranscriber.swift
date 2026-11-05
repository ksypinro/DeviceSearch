#if canImport(Speech) && os(iOS)
import AVFoundation
import Foundation
import Speech
import Synchronization

/// On-device speech-to-text for the microphone button (design doc §3 C20, decision D08).
/// Recognition never leaves the device (`requiresOnDeviceRecognition`); when the locale has no on-device
/// model, voice is unavailable rather than falling back to the server.
///
/// Info.plist: NSMicrophoneUsageDescription and NSSpeechRecognitionUsageDescription.
public final class SpeechVoiceTranscriber: VoiceTranscribing, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer?
    private let state = Mutex<Session?>(nil)

    /// The audio engine, request and task of one listening session. `append` is called on the audio thread,
    /// which `SFSpeechAudioBufferRecognitionRequest` supports.
    private final class Session: @unchecked Sendable {
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        var task: SFSpeechRecognitionTask?
    }

    public init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    public func isAvailable() async -> Bool {
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return false }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    public func transcripts() async throws -> AsyncThrowingStream<VoiceTranscript, any Error> {
        guard let recognizer, await isAvailable() else { throw CocoaError(.featureUnsupported) }
        await stop()
        let session = Session()
        session.request.requiresOnDeviceRecognition = true
        session.request.shouldReportPartialResults = true

        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audio.setActive(true, options: .notifyOthersOnDeactivation)

        let input = session.engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            session.request.append(buffer)
        }
        session.engine.prepare()
        try session.engine.start()
        state.withLock { $0 = session }

        return AsyncThrowingStream { continuation in
            session.task = recognizer.recognitionTask(with: session.request) { result, error in
                if let result {
                    let transcript = VoiceTranscript(text: result.bestTranscription.formattedString, isFinal: result.isFinal)
                    continuation.yield(transcript)
                    if result.isFinal { continuation.finish() }
                } else if let error {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.stop() }
            }
        }
    }

    public func stop() async {
        let session = state.withLock { current -> Session? in
            defer { current = nil }
            return current
        }
        guard let session else { return }
        session.engine.stop()
        session.engine.inputNode.removeTap(onBus: 0)
        session.request.endAudio()
        session.task?.cancel()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif

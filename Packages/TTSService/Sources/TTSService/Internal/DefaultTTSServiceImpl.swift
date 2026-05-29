import AVFoundation
import Foundation

/// Core implementation of TTS behaviour. Isolated to `@MainActor` for all synthesizer
/// interactions. Exposed to the `@unchecked Sendable` `DefaultTTSService` shell via
/// async forwarding calls.
@MainActor
final class DefaultTTSServiceImpl {

    // MARK: - Public-facing stream

    let events: AsyncStream<TTSEvent>

    // MARK: - Private

    private let synthesizer: AVSpeechSynthesizer
    private let delegateAdapter: SynthesizerDelegateAdapter

    // MARK: - Init

    init() {
        let adapter = SynthesizerDelegateAdapter()
        let synth = AVSpeechSynthesizer()
        synth.delegate = adapter

        var continuation: AsyncStream<TTSEvent>.Continuation!
        let stream = AsyncStream<TTSEvent>(bufferingPolicy: .bufferingNewest(64)) { cont in
            continuation = cont
        }
        adapter.eventsContinuation = continuation

        self.synthesizer = synth
        self.delegateAdapter = adapter
        self.events = stream
    }

    // MARK: - Voice discovery (nonisolated helpers delegate to global functions)

    nonisolated func bestVoice(forLanguage tag: String) -> TTSVoice? {
        bestInstalledVoice(forLanguage: tag)
    }

    nonisolated func hasHighQualityVoice(forLanguage tag: String) -> Bool {
        guard let voice = bestInstalledVoice(forLanguage: tag) else { return false }
        return voice.quality == .enhanced || voice.quality == .premium
    }

    // MARK: - Playback

    func speak(_ text: String, voice: TTSVoice, rate: Double) async {
        // Stop any in-flight utterance. This will trigger didCancel, which resolves the
        // old continuation if one is pending.
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        // Configure audio session; emit failure and return on error.
        if let errorMsg = activateAudioSession() {
            delegateAdapter.eventsContinuation?.yield(.failed(reason: errorMsg))
            return
        }

        let utterance = AVSpeechUtterance(string: text)
        if let avVoice = AVSpeechSynthesisVoice(identifier: voice.identifier) {
            utterance.voice = avVoice
        }
        utterance.rate = clampRate(rate)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            delegateAdapter.speakContinuation = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        // The delegate's didCancel will fire and resolve the continuation + emit .cancelled.
        // If no utterance is in flight, we do nothing further.
    }
}

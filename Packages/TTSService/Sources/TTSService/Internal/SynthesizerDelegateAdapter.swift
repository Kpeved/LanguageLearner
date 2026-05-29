import AVFoundation
import Foundation

/// `AVSpeechSynthesizerDelegate` adapter that bridges delegate callbacks into a
/// checked-continuation plus an `AsyncStream` continuation for `TTSEvent` values.
///
/// Must be used on the main thread because `AVSpeechSynthesizer` requires it.
@MainActor
final class SynthesizerDelegateAdapter: NSObject, AVSpeechSynthesizerDelegate {

    // MARK: - State

    /// Continuation resumed exactly once per utterance when it finishes or is cancelled.
    var speakContinuation: CheckedContinuation<Void, Never>?

    /// Stream continuation used to push `TTSEvent` values for UI consumption.
    var eventsContinuation: AsyncStream<TTSEvent>.Continuation?

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.eventsContinuation?.yield(.started)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.eventsContinuation?.yield(.finished)
            self.speakContinuation?.resume()
            self.speakContinuation = nil
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.eventsContinuation?.yield(.cancelled)
            self.speakContinuation?.resume()
            self.speakContinuation = nil
        }
    }
}

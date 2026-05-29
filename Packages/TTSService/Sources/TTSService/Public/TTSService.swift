import Foundation

/// Protocol for text-to-speech synthesis. All methods are callable from any isolation context.
/// Concrete implementations must ensure thread-safety internally.
public protocol TTSService: AnyObject, Sendable {
    /// Returns the highest-quality available voice for the given BCP-47 language tag, or nil if none
    /// is installed on-device.
    func bestVoice(forLanguage tag: String) -> TTSVoice?

    /// Returns true when the best voice for the given language tag is `.enhanced` or `.premium`.
    func hasHighQualityVoice(forLanguage tag: String) -> Bool

    /// Speaks `text` using the given voice at the specified rate.
    ///
    /// - Parameters:
    ///   - text: The string to be spoken.
    ///   - voice: A `TTSVoice` previously obtained from `bestVoice(forLanguage:)`.
    ///   - rate: Playback rate in the range 0.3...1.0. Values outside that range are clamped.
    ///           1.0 maps to `AVSpeechUtteranceDefaultSpeechRate`; 0.3 maps to
    ///           `AVSpeechUtteranceMinimumSpeechRate`.
    ///
    /// This method suspends until the utterance finishes or is cancelled.
    /// Any in-flight utterance is stopped before the new one starts.
    func speak(_ text: String, voice: TTSVoice, rate: Double) async

    /// Immediately stops any in-flight utterance and emits `.cancelled` on `events`.
    func stop()

    /// An unbounded `AsyncStream` of `TTSEvent` values. Subscribe from UI layers to drive
    /// playback indicators. Buffered with a capacity of 64 events.
    var events: AsyncStream<TTSEvent> { get }
}

/// Default production implementation backed by `AVSpeechSynthesizer`.
///
/// `@unchecked Sendable` because internal mutable state is fully guarded by `@MainActor`
/// inside `DefaultTTSServiceImpl`. The `nonisolated(unsafe)` stored property is safe
/// because it is written exactly once at construction and never mutated afterward.
public final class DefaultTTSService: TTSService, @unchecked Sendable {

    // MARK: - Init

    public init() {
        // DefaultTTSServiceImpl is @MainActor; use MainActor.assumeIsolated when
        // DefaultTTSService is created from the main thread (the normal app path).
        // If somehow called off-main, Task{@MainActor} would be required, but per the design
        // all app-level service construction happens on the main thread.
        _impl = MainActor.assumeIsolated { DefaultTTSServiceImpl() }
    }

    // MARK: - TTSService

    public func bestVoice(forLanguage tag: String) -> TTSVoice? {
        _impl.bestVoice(forLanguage: tag)
    }

    public func hasHighQualityVoice(forLanguage tag: String) -> Bool {
        _impl.hasHighQualityVoice(forLanguage: tag)
    }

    public func speak(_ text: String, voice: TTSVoice, rate: Double) async {
        await _impl.speak(text, voice: voice, rate: rate)
    }

    public func stop() {
        Task { @MainActor [_impl] in
            _impl.stop()
        }
    }

    public var events: AsyncStream<TTSEvent> {
        _impl.events
    }

    // MARK: - Private

    // Written once at construction, read-only thereafter. All mutating accesses inside the
    // impl are @MainActor-isolated. DefaultTTSServiceImpl is @MainActor-isolated which
    // satisfies Sendable checking, so no nonisolated(unsafe) annotation is needed.
    private let _impl: DefaultTTSServiceImpl
}

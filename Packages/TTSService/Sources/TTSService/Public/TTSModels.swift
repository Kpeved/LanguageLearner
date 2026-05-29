import Foundation

/// A voice available for speech synthesis, identified by its BCP-47 language tag and quality tier.
public struct TTSVoice: Sendable, Equatable, Hashable {
    /// The underlying `AVSpeechSynthesisVoice.identifier` value.
    public let identifier: String
    /// BCP-47 language tag (e.g. "en-US", "es-ES").
    public let language: String
    /// Quality tier of this voice.
    public let quality: Quality

    public init(identifier: String, language: String, quality: Quality) {
        self.identifier = identifier
        self.language = language
        self.quality = quality
    }

    /// Quality tier, ordered from lowest to highest: default < enhanced < premium.
    public enum Quality: Sendable, Equatable, Hashable, Comparable {
        case `default`
        case enhanced
        case premium
    }
}

/// Events emitted by `TTSService` during the lifecycle of a speech utterance.
public enum TTSEvent: Sendable, Equatable {
    case started
    case finished
    case cancelled
    case failed(reason: String)
}

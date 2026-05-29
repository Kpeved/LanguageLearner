import Foundation

/// Reader display and playback settings persisted by the caller.
public struct ReaderSettings: Codable, Sendable, Equatable {
    /// Font size in points. Valid range: 14...28.
    public var fontPointSize: Double
    /// TTS playback rate. Valid range: 0.3...1.0.
    public var ttsRate: Double

    public init(fontPointSize: Double, ttsRate: Double) {
        self.fontPointSize = fontPointSize
        self.ttsRate = ttsRate
    }

    /// Sensible default values within specified ranges.
    public static let `default` = ReaderSettings(fontPointSize: 18.0, ttsRate: 0.5)
}

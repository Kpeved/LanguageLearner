import AVFoundation
import Foundation

// MARK: - Quality mapping

/// Maps a raw `AVSpeechSynthesisVoiceQuality.rawValue` integer to a `TTSVoice.Quality`.
/// Extracted as a standalone function so it can be tested without spinning up real voices.
///
/// - AVSpeechSynthesisVoiceQuality.default  == 1
/// - AVSpeechSynthesisVoiceQuality.enhanced == 2
/// - AVSpeechSynthesisVoiceQuality.premium  == 3  (iOS 16+)
func voiceQuality(fromRawValue rawValue: Int) -> TTSVoice.Quality {
    switch rawValue {
    case 2:
        return .enhanced
    case 3:
        return .premium
    default:
        return .default
    }
}

// MARK: - Rate clamping

/// Clamps `rate` to 0.3...1.0 and maps linearly onto the AVSpeech rate range
/// `AVSpeechUtteranceMinimumSpeechRate`...`AVSpeechUtteranceDefaultSpeechRate`.
///
/// Linear mapping:
///   input 0.3 -> AVSpeechUtteranceMinimumSpeechRate
///   input 1.0 -> AVSpeechUtteranceDefaultSpeechRate
///
/// Note: AVSpeechUtteranceMaximumSpeechRate is intentionally not exposed; the design
/// caps the user-visible maximum at the default rate to keep playback intelligible.
func clampRate(_ rate: Double) -> Float {
    let clamped = min(max(rate, 0.3), 1.0)
    let minInput: Double = 0.3
    let maxInput: Double = 1.0
    let minOutput = Double(AVSpeechUtteranceMinimumSpeechRate)
    let maxOutput = Double(AVSpeechUtteranceDefaultSpeechRate)
    let t = (clamped - minInput) / (maxInput - minInput)
    return Float(minOutput + t * (maxOutput - minOutput))
}

// MARK: - Voice selection

/// Pure function that selects the best `TTSVoice` from a pre-built list of candidates
/// for the given BCP-47 language tag.
///
/// Selection rules:
///   1. Higher quality wins over lower quality.
///   2. Within the same quality tier, exact language-tag match (e.g. "es-ES") wins over
///      language-only match (e.g. "es" matching "es-ES").
func selectBestVoice(from voices: [TTSVoice], language tag: String) -> TTSVoice? {
    let normalised = tag.lowercased()
    let targetLangCode = Locale(identifier: normalised).language.languageCode?.identifier ?? String(normalised.split(separator: "-").first ?? Substring(normalised))

    // Partition into exact-tag matches and language-only matches.
    let exactMatches = voices.filter { $0.language.lowercased() == normalised }
    let langOnlyMatches = voices.filter {
        let code = Locale(identifier: $0.language).language.languageCode?.identifier
            ?? String($0.language.split(separator: "-").first ?? Substring($0.language))
        return code.lowercased() == targetLangCode && $0.language.lowercased() != normalised
    }

    // Prefer exact over lang-only, then highest quality within each group.
    if let best = (exactMatches + langOnlyMatches).max(by: { lhs, rhs in
        if lhs.quality != rhs.quality {
            return lhs.quality < rhs.quality
        }
        // Same quality: prefer exact match (exact matches appear first in the combined array).
        let lhsExact = lhs.language.lowercased() == normalised
        let rhsExact = rhs.language.lowercased() == normalised
        if lhsExact != rhsExact { return !lhsExact }
        return false
    }) {
        return best
    }
    return nil
}

// MARK: - AVSpeechSynthesisVoice -> TTSVoice conversion

/// Converts the device's installed voices into `TTSVoice` values and selects the best
/// one for the given BCP-47 language tag.
func bestInstalledVoice(forLanguage tag: String) -> TTSVoice? {
    let allVoices = AVSpeechSynthesisVoice.speechVoices()
    let candidates: [TTSVoice] = allVoices.map { av in
        TTSVoice(
            identifier: av.identifier,
            language: av.language,
            quality: voiceQuality(fromRawValue: av.quality.rawValue)
        )
    }
    // Honour the voice the user picked in Settings > Accessibility > Spoken Content > Voices.
    // `AVSpeechSynthesisVoice(language:)` returns that user-selected default for the language,
    // so we prefer it over our own highest-quality heuristic. Without this, changing the
    // selected premium voice in Settings has no effect because `selectBestVoice` keeps
    // returning whichever same-quality voice it happens to rank first.
    if let systemDefault = AVSpeechSynthesisVoice(language: tag),
       let match = candidates.first(where: { $0.identifier == systemDefault.identifier }) {
        return match
    }
    return selectBestVoice(from: candidates, language: tag)
}

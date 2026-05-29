import Testing
@testable import TTSService

// MARK: - Voice quality mapping

@Suite("Voice quality mapping")
struct VoiceQualityTests {

    @Test("Raw value 1 (default) maps to .default")
    func defaultQuality() {
        #expect(voiceQuality(fromRawValue: 1) == .default)
    }

    @Test("Raw value 2 (enhanced) maps to .enhanced")
    func enhancedQuality() {
        #expect(voiceQuality(fromRawValue: 2) == .enhanced)
    }

    @Test("Raw value 3 (premium) maps to .premium")
    func premiumQuality() {
        #expect(voiceQuality(fromRawValue: 3) == .premium)
    }

    @Test("Unknown raw values map to .default")
    func unknownQuality() {
        #expect(voiceQuality(fromRawValue: 0) == .default)
        #expect(voiceQuality(fromRawValue: 99) == .default)
        #expect(voiceQuality(fromRawValue: -1) == .default)
    }
}

// MARK: - Quality Comparable ordering

@Suite("TTSVoice.Quality ordering")
struct QualityOrderingTests {

    @Test("default < enhanced < premium")
    func ordering() {
        #expect(TTSVoice.Quality.default < .enhanced)
        #expect(TTSVoice.Quality.enhanced < .premium)
        #expect(TTSVoice.Quality.default < .premium)
    }

    @Test("Same quality values are equal")
    func equality() {
        #expect(TTSVoice.Quality.default == .default)
        #expect(TTSVoice.Quality.enhanced == .enhanced)
        #expect(TTSVoice.Quality.premium == .premium)
    }
}

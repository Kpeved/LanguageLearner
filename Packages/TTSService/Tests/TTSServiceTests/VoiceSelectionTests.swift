import Testing
@testable import TTSService

@Suite("Voice selection - selectBestVoice")
struct VoiceSelectionTests {

    // MARK: - Helpers

    func makeVoice(
        id: String,
        language: String,
        quality: TTSVoice.Quality
    ) -> TTSVoice {
        TTSVoice(identifier: id, language: language, quality: quality)
    }

    // MARK: - Edge cases

    @Test("Empty list returns nil")
    func emptyListReturnsNil() {
        let result = selectBestVoice(from: [], language: "en-US")
        #expect(result == nil)
    }

    @Test("No matching language returns nil")
    func noMatchReturnsNil() {
        let voices = [makeVoice(id: "fr-1", language: "fr-FR", quality: .enhanced)]
        let result = selectBestVoice(from: voices, language: "en-US")
        #expect(result == nil)
    }

    // MARK: - Single voice

    @Test("Single default-quality voice is returned")
    func singleDefaultVoiceReturned() {
        let voice = makeVoice(id: "en-1", language: "en-US", quality: .default)
        let result = selectBestVoice(from: [voice], language: "en-US")
        #expect(result == voice)
    }

    // MARK: - Quality tiebreaking

    @Test("Enhanced beats default")
    func enhancedBeatsDefault() {
        let def = makeVoice(id: "en-1", language: "en-US", quality: .default)
        let enh = makeVoice(id: "en-2", language: "en-US", quality: .enhanced)
        let result = selectBestVoice(from: [def, enh], language: "en-US")
        #expect(result == enh)
    }

    @Test("Premium beats enhanced")
    func premiumBeatsEnhanced() {
        let enh = makeVoice(id: "en-2", language: "en-US", quality: .enhanced)
        let prem = makeVoice(id: "en-3", language: "en-US", quality: .premium)
        let result = selectBestVoice(from: [enh, prem], language: "en-US")
        #expect(result == prem)
    }

    @Test("Premium beats default")
    func premiumBeatsDefault() {
        let def = makeVoice(id: "en-1", language: "en-US", quality: .default)
        let prem = makeVoice(id: "en-3", language: "en-US", quality: .premium)
        let result = selectBestVoice(from: [def, prem], language: "en-US")
        #expect(result == prem)
    }

    // MARK: - Exact vs language-only match tiebreaking

    @Test("Exact language tag beats language-only match at same quality")
    func exactTagBeatsLangOnlyAtSameQuality() {
        // "es" voice matches "es-ES" query via language code, but "es-ES" is an exact match.
        let langOnly = makeVoice(id: "es-gen", language: "es", quality: .enhanced)
        let exact = makeVoice(id: "es-es", language: "es-ES", quality: .enhanced)
        let result = selectBestVoice(from: [langOnly, exact], language: "es-ES")
        #expect(result == exact)
    }

    @Test("Higher quality lang-only match beats lower quality exact match")
    func higherQualityLangOnlyBeatsLowerQualityExact() {
        let exactDefault = makeVoice(id: "es-es-def", language: "es-ES", quality: .default)
        let langOnlyPremium = makeVoice(id: "es-prem", language: "es", quality: .premium)
        let result = selectBestVoice(from: [exactDefault, langOnlyPremium], language: "es-ES")
        #expect(result == langOnlyPremium)
    }

    @Test("Case-insensitive language tag matching")
    func caseInsensitiveMatching() {
        let voice = makeVoice(id: "de-1", language: "de-DE", quality: .enhanced)
        // Query in uppercase should still match.
        let result = selectBestVoice(from: [voice], language: "DE-DE")
        #expect(result == voice)
    }

    // MARK: - Multiple voices, best wins

    @Test("Best voice wins across mixed quality and languages")
    func bestWinsInMixedList() {
        let voices = [
            makeVoice(id: "en-1", language: "en-US", quality: .default),
            makeVoice(id: "en-2", language: "en-US", quality: .enhanced),
            makeVoice(id: "fr-1", language: "fr-FR", quality: .premium),
        ]
        let result = selectBestVoice(from: voices, language: "en-US")
        #expect(result?.identifier == "en-2")
    }
}

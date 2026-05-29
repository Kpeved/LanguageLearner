import AVFoundation
import Testing
@testable import TTSService

@Suite("Rate clamping and mapping")
struct RateClampingTests {

    @Test("Rate below minimum clamps to 0.3")
    func belowMinimumClampsToMin() {
        let result = clampRate(0.0)
        let expected = clampRate(0.3)
        #expect(result == expected)
    }

    @Test("Rate above maximum clamps to 1.0")
    func aboveMaximumClampsToMax() {
        let result = clampRate(1.5)
        let expected = clampRate(1.0)
        #expect(result == expected)
    }

    @Test("Rate 1.0 maps to AVSpeechUtteranceDefaultSpeechRate")
    func maxRateMapsToDefault() {
        let result = clampRate(1.0)
        #expect(result == AVSpeechUtteranceDefaultSpeechRate)
    }

    @Test("Rate 0.3 maps to AVSpeechUtteranceMinimumSpeechRate")
    func minRateMapsToMinimum() {
        let result = clampRate(0.3)
        #expect(result == AVSpeechUtteranceMinimumSpeechRate)
    }

    @Test("Midpoint rate maps linearly between min and max")
    func midpointLinearMapping() {
        // input midpoint between 0.3 and 1.0 is 0.65
        let mid = clampRate(0.65)
        let minOut = AVSpeechUtteranceMinimumSpeechRate
        let maxOut = AVSpeechUtteranceDefaultSpeechRate
        let expected = minOut + (maxOut - minOut) * 0.5
        #expect(abs(mid - expected) < 0.0001)
    }

    @Test("Negative rate clamps to minimum speech rate")
    func negativeRateClampsToMin() {
        let result = clampRate(-5.0)
        #expect(result == AVSpeechUtteranceMinimumSpeechRate)
    }
}

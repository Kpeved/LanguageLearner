import Foundation

// AVAudioSession is only available on iOS / tvOS. On macOS (Swift CLI test runs) we skip
// audio session activation entirely - the synthesizer still works without it on macOS.
#if canImport(UIKit)
import AVFoundation

/// Activates `AVAudioSession` for spoken-audio playback with duck-others behaviour.
/// Returns an error string on failure; returns nil on success.
func activateAudioSession() -> String? {
    let session = AVAudioSession.sharedInstance()
    do {
        try session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try session.setActive(true)
        return nil
    } catch {
        return error.localizedDescription
    }
}
#else
/// No-op on platforms that do not have AVAudioSession (macOS Swift CLI).
func activateAudioSession() -> String? {
    return nil
}
#endif

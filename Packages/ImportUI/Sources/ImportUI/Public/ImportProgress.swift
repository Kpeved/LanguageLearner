import Foundation
import LibraryStore

/// Describes every distinct stage of the two-file EPUB import flow.
public enum ImportPhase: Sendable, Equatable {
    /// No import in progress.
    case idle
    /// The document picker is open so the user can choose the target-language EPUB.
    case pickingTarget
    /// The document picker is open so the user can choose the native-language EPUB.
    case pickingNative
    /// The target EPUB is being parsed; `progress` is in 0...1.
    case parsingTarget(progress: Double)
    /// The native EPUB is being parsed; `progress` is in 0...1.
    case parsingNative(progress: Double)
    /// Both EPUBs have been parsed and are being persisted to the library.
    case writingToStore
    /// Import completed successfully. Carries the new paired entry's identifier.
    case done(PairedEntryID)
    /// Import failed. `message` is a human-readable error description.
    case failed(String)
}

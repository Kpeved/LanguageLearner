import Foundation

/// Lifecycle phase of the background paragraph-alignment computation for one paired entry.
public enum AlignmentPhase: String, Codable, Sendable, Equatable {
    /// No computation has started yet (legacy entries imported before diagnostics existed).
    case pending
    /// Embedding + Needleman-Wunsch is running in a background task.
    case running
    /// A table was built and persisted. `mappedParagraphs` tells how many source
    /// paragraphs got a target range.
    case completed
    /// The build threw. `message` carries the human-readable reason (no embedding model
    /// for the language, asset download failed, etc.). The reader falls back to
    /// proportional mapping.
    case failed
}

/// Snapshot of how the per-paragraph alignment was (or wasn't) computed for an entry.
///
/// Persisted alongside the `ParagraphAlignmentTable` so the UI can explain why a tap
/// lands on a proportionally-approximated paragraph instead of an embedding-aligned range.
public struct AlignmentDiagnostics: Codable, Sendable, Equatable {
    public var phase: AlignmentPhase
    /// Fraction of source chapters processed, 0...1.
    public var progress: Double
    /// BCP-47 tag of the side being read (the target/learning language).
    public var sourceLanguage: String
    /// BCP-47 tag of the translation side.
    public var targetLanguage: String
    /// Total source chapters the aligner will process.
    public var totalChapters: Int
    /// Source chapters that produced at least one mapped paragraph.
    public var alignedChapters: Int
    /// Source paragraphs that received a target range.
    public var mappedParagraphs: Int
    /// Source paragraphs the aligner could not match (gaps / empty chapters).
    public var unmappedParagraphs: Int
    /// Error reason when `phase == .failed`, or a short status note otherwise. May be nil.
    public var message: String?
    /// When this snapshot was last written.
    public var updatedAt: Date

    public init(
        phase: AlignmentPhase,
        progress: Double = 0,
        sourceLanguage: String = "",
        targetLanguage: String = "",
        totalChapters: Int = 0,
        alignedChapters: Int = 0,
        mappedParagraphs: Int = 0,
        unmappedParagraphs: Int = 0,
        message: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.phase = phase
        self.progress = progress
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.totalChapters = totalChapters
        self.alignedChapters = alignedChapters
        self.mappedParagraphs = mappedParagraphs
        self.unmappedParagraphs = unmappedParagraphs
        self.message = message
        self.updatedAt = updatedAt
    }
}

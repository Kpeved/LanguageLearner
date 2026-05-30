import Foundation
import SwiftData

/// Represents a single parsed book (one language) stored on disk.
@Model public final class Book {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var author: String?
    public var language: String
    public var coverPNG: Data?
    /// Titles for each chapter, used for navigation UI.
    public var chapterTitles: [String?]
    /// Paragraph counts per chapter; enables alignment lookup without loading chapter text.
    public var paragraphCounts: [Int]
    /// Binary plist-encoded AlignmentProfile for this book.
    public var alignmentProfileData: Data
    /// The relative directory name under the App Support root where chapters are stored.
    public var storageDirName: String

    public init(
        id: UUID,
        title: String,
        author: String?,
        language: String,
        coverPNG: Data?,
        chapterTitles: [String?],
        paragraphCounts: [Int],
        alignmentProfileData: Data,
        storageDirName: String
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.language = language
        self.coverPNG = coverPNG
        self.chapterTitles = chapterTitles
        self.paragraphCounts = paragraphCounts
        self.alignmentProfileData = alignmentProfileData
        self.storageDirName = storageDirName
    }
}

/// Represents a paired (target + native) library entry.
@Model public final class PairedEntry {
    @Attribute(.unique) public var id: UUID
    public var createdAt: Date
    public var targetBook: Book
    public var nativeBook: Book
    public var lastReadChapterIndex: Int
    public var lastReadParagraphIndex: Int
    public var lastReadScrollFraction: Double
    /// Integer shift applied to the source chapter index when computing the native
    /// chapter for chapter-anchored alignment. Negative values mean the target
    /// book has leading content (e.g. a translator preface) absent from the native.
    public var targetChapterOffset: Int = 0

    /// Optional precomputed per-paragraph alignment from target -> native.
    /// Stored as a binary plist of `ParagraphAlignmentTable`. nil when the import
    /// was unable to build a table (no embedding model for the language, etc.).
    public var paragraphAlignmentData: Data?

    /// Optional JSON-encoded `AlignmentDiagnostics` describing the outcome of the
    /// background alignment build (phase, progress, error reason, mapped counts).
    /// nil for legacy entries imported before diagnostics existed.
    public var alignmentDiagnosticsData: Data?

    public init(
        id: UUID,
        createdAt: Date,
        targetBook: Book,
        nativeBook: Book,
        lastReadChapterIndex: Int,
        lastReadParagraphIndex: Int,
        lastReadScrollFraction: Double,
        targetChapterOffset: Int = 0,
        paragraphAlignmentData: Data? = nil,
        alignmentDiagnosticsData: Data? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.targetBook = targetBook
        self.nativeBook = nativeBook
        self.lastReadChapterIndex = lastReadChapterIndex
        self.lastReadParagraphIndex = lastReadParagraphIndex
        self.lastReadScrollFraction = lastReadScrollFraction
        self.targetChapterOffset = targetChapterOffset
        self.paragraphAlignmentData = paragraphAlignmentData
        self.alignmentDiagnosticsData = alignmentDiagnosticsData
    }
}

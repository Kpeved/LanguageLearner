import Foundation

/// Unique identifier for a paired library entry.
public typealias PairedEntryID = UUID

/// Identifies a specific chapter within a book stored in the library.
public struct ChapterRef: Sendable, Equatable, Hashable {
    public let bookID: UUID
    public let chapterIndex: Int

    public init(bookID: UUID, chapterIndex: Int) {
        self.bookID = bookID
        self.chapterIndex = chapterIndex
    }
}

/// The last-read position for a paired entry. All fields default to zero when
/// a book has never been opened, so this type is always non-optional.
public struct LastReadPosition: Codable, Sendable, Equatable {
    public let chapterIndex: Int
    public let paragraphIndex: Int
    /// A value in 0...1 representing scroll progress within the paragraph.
    public let scrollFractionWithinParagraph: Double

    public init(chapterIndex: Int, paragraphIndex: Int, scrollFractionWithinParagraph: Double) {
        self.chapterIndex = chapterIndex
        self.paragraphIndex = paragraphIndex
        self.scrollFractionWithinParagraph = scrollFractionWithinParagraph
    }
}

/// A lightweight, Sendable summary of a PairedEntry suitable for displaying in the library list.
public struct PairedEntrySummary: Sendable, Identifiable, Equatable {
    public let id: PairedEntryID
    public let title: String
    public let author: String?
    public let coverPNG: Data?
    public let targetLanguage: String
    public let nativeLanguage: String
    public let createdAt: Date

    public init(
        id: PairedEntryID,
        title: String,
        author: String?,
        coverPNG: Data?,
        targetLanguage: String,
        nativeLanguage: String,
        createdAt: Date
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.coverPNG = coverPNG
        self.targetLanguage = targetLanguage
        self.nativeLanguage = nativeLanguage
        self.createdAt = createdAt
    }
}

/// Errors thrown by LibraryStore operations.
public enum LibraryError: Error, Sendable, Equatable {
    case bookNotFound(UUID)
    case chapterNotFound(ChapterRef)
    case storageFull
    case ioFailure(message: String)
}

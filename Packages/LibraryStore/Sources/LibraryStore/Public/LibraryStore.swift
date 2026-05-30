import Foundation
import SwiftData
import EPUBKit
import Alignment

/// The primary interface for all library persistence operations.
///
/// - Note: `lastReadPosition(forEntry:)` always returns a non-optional `LastReadPosition`.
///   When a book has never been opened the returned value has all fields set to zero
///   (chapterIndex: 0, paragraphIndex: 0, scrollFractionWithinParagraph: 0).
///   This deviates from the original design-doc signature (`LastReadPosition?`) to keep
///   position semantics simple; a nil return cannot be distinguished from "first paragraph" anyway.
public protocol LibraryStore: Sendable {
    /// Imports a target + native EPUB pair, writes chapters to disk, and persists metadata.
    func importPair(
        target: EPUBBook,
        native: EPUBBook,
        targetSource: URL,
        nativeSource: URL
    ) async throws -> PairedEntryID

    /// Returns all library entries sorted by creation date, newest first.
    func allEntries() async throws -> [PairedEntrySummary]

    /// Removes a paired entry along with its on-disk chapter data and SwiftData rows.
    func deleteEntry(_ id: PairedEntryID) async throws

    /// Returns the target and native book UUIDs for the given paired entry.
    func bookIDs(forEntry id: PairedEntryID) async throws -> (target: UUID, native: UUID)

    /// Loads a chapter from the on-disk JSON cache (LRU-backed).
    func loadChapter(_ ref: ChapterRef) async throws -> EPUBChapter

    /// Decodes and returns the alignment profile for the given book.
    func alignmentProfile(forBook id: UUID) async throws -> AlignmentProfile

    /// Returns the last-read position for the entry.
    /// Returns zeros when the entry has never been explicitly saved.
    func lastReadPosition(forEntry id: PairedEntryID) async throws -> LastReadPosition

    /// Persists the current reading position for the entry.
    func updateLastReadPosition(_ pos: LastReadPosition, forEntry id: PairedEntryID) async throws

    /// Returns the per-entry integer chapter offset applied to the source side when mapping
    /// to the native side. Defaults to 0.
    func chapterOffset(forEntry id: PairedEntryID) async throws -> Int

    /// Persists the chapter offset for the entry.
    func updateChapterOffset(_ offset: Int, forEntry id: PairedEntryID) async throws

    /// Returns chapter titles for the given book (one per chapter, in spine order).
    func chapterTitles(forBook id: UUID) async throws -> [String?]

    /// Returns the precomputed per-paragraph alignment table for the given entry,
    /// or nil if none was computed (e.g. embedding model unavailable for the language).
    func paragraphAlignment(forEntry id: PairedEntryID) async throws -> ParagraphAlignmentTable?

    /// Persists a new alignment table for the entry. Pass nil to clear.
    func updateParagraphAlignment(_ table: ParagraphAlignmentTable?, forEntry id: PairedEntryID) async throws

    /// Returns the latest diagnostics snapshot for the entry's background alignment build,
    /// or nil for legacy entries that predate diagnostics.
    func alignmentDiagnostics(forEntry id: PairedEntryID) async throws -> AlignmentDiagnostics?

    /// Persists a diagnostics snapshot for the entry. Pass nil to clear.
    func updateAlignmentDiagnostics(_ diagnostics: AlignmentDiagnostics?, forEntry id: PairedEntryID) async throws

    /// Re-runs the background paragraph alignment for the whole entry using its current
    /// chapter offset. Returns immediately; outcome surfaces via `alignmentDiagnostics`.
    func recomputeAlignment(forEntry id: PairedEntryID) async throws

    /// Aligns one target chapter's paragraphs against its paired native chapter
    /// (`targetChapterIndex + chapterOffset`) and merges the result into the stored table.
    /// Awaits completion. This is the manual, per-chapter alignment path.
    func alignChapter(forEntry id: PairedEntryID, targetChapterIndex: Int) async throws
}

/// Concrete, production implementation of `LibraryStore`.
///
/// `ModelContext` is `@MainActor`-bound; all SwiftData work is routed through an
/// internal `@MainActor` class. `DefaultLibraryStore` itself is `@unchecked Sendable`
/// because it holds only the `@MainActor` actor reference (safe to capture) and an
/// `NSCache`-based LRU (internally thread-safe).
public final class DefaultLibraryStore: LibraryStore, @unchecked Sendable {
    private let impl: LibraryStoreImpl

    /// - Parameters:
    ///   - modelContext: The SwiftData context to use. Must be accessed on the main actor.
    ///   - fileManager: File manager instance (injected for testability).
    ///   - appSupportRoot: Override the App Support root directory. Pass `nil` to resolve
    ///     `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first`.
    public init(
        modelContext: ModelContext,
        fileManager: FileManager = .default,
        appSupportRoot: URL? = nil
    ) {
        self.impl = LibraryStoreImpl(
            modelContext: modelContext,
            fileManager: fileManager,
            appSupportRoot: appSupportRoot
        )
    }

    public func importPair(
        target: EPUBBook,
        native: EPUBBook,
        targetSource: URL,
        nativeSource: URL
    ) async throws -> PairedEntryID {
        try await impl.importPair(target: target, native: native, targetSource: targetSource, nativeSource: nativeSource)
    }

    public func allEntries() async throws -> [PairedEntrySummary] {
        try await impl.allEntries()
    }

    public func deleteEntry(_ id: PairedEntryID) async throws {
        try await impl.deleteEntry(id)
    }

    public func bookIDs(forEntry id: PairedEntryID) async throws -> (target: UUID, native: UUID) {
        try await impl.bookIDs(forEntry: id)
    }

    public func loadChapter(_ ref: ChapterRef) async throws -> EPUBChapter {
        try await impl.loadChapter(ref)
    }

    public func alignmentProfile(forBook id: UUID) async throws -> AlignmentProfile {
        try await impl.alignmentProfile(forBook: id)
    }

    public func lastReadPosition(forEntry id: PairedEntryID) async throws -> LastReadPosition {
        try await impl.lastReadPosition(forEntry: id)
    }

    public func updateLastReadPosition(_ pos: LastReadPosition, forEntry id: PairedEntryID) async throws {
        try await impl.updateLastReadPosition(pos, forEntry: id)
    }

    public func chapterOffset(forEntry id: PairedEntryID) async throws -> Int {
        try await impl.chapterOffset(forEntry: id)
    }

    public func updateChapterOffset(_ offset: Int, forEntry id: PairedEntryID) async throws {
        try await impl.updateChapterOffset(offset, forEntry: id)
    }

    public func chapterTitles(forBook id: UUID) async throws -> [String?] {
        try await impl.chapterTitles(forBook: id)
    }

    public func paragraphAlignment(forEntry id: PairedEntryID) async throws -> ParagraphAlignmentTable? {
        try await impl.paragraphAlignment(forEntry: id)
    }

    public func updateParagraphAlignment(_ table: ParagraphAlignmentTable?, forEntry id: PairedEntryID) async throws {
        try await impl.updateParagraphAlignment(table, forEntry: id)
    }

    public func alignmentDiagnostics(forEntry id: PairedEntryID) async throws -> AlignmentDiagnostics? {
        try await impl.alignmentDiagnostics(forEntry: id)
    }

    public func updateAlignmentDiagnostics(_ diagnostics: AlignmentDiagnostics?, forEntry id: PairedEntryID) async throws {
        try await impl.updateAlignmentDiagnostics(diagnostics, forEntry: id)
    }

    public func recomputeAlignment(forEntry id: PairedEntryID) async throws {
        try await impl.recomputeAlignment(forEntry: id)
    }

    public func alignChapter(forEntry id: PairedEntryID, targetChapterIndex: Int) async throws {
        try await impl.alignChapter(forEntry: id, targetChapterIndex: targetChapterIndex)
    }
}

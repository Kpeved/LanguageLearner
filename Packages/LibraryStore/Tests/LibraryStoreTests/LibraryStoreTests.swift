import Testing
import Foundation
import SwiftData
import EPUBKit
import Alignment
@testable import LibraryStore

// MARK: - Test helpers

private func makeContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: PairedEntry.self, Book.self, configurations: config)
}

private func makeTempRoot() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func makeStore(context: ModelContext, root: URL) -> DefaultLibraryStore {
    DefaultLibraryStore(modelContext: context, fileManager: .default, appSupportRoot: root)
}

private func sampleBook(title: String = "Test Book", language: String = "en", chapters: Int = 2) -> EPUBBook {
    let chaps = (0..<chapters).map { i in
        EPUBChapter(title: "Chapter \(i)", paragraphs: ["Paragraph A of \(i)", "Paragraph B of \(i)"])
    }
    return EPUBBook(title: title, author: "Test Author", language: language, coverPNG: nil, chapters: chaps)
}

// MARK: - Tests

@Suite("LibraryStore")
struct LibraryStoreTests {

    // MARK: importPair persists chapters to disk

    @Test("importPair writes chapter JSON files to disk")
    @MainActor
    func importPairWritesChaptersToDisk() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(context: context, root: root)
        let target = sampleBook(title: "Target Book", language: "de", chapters: 2)
        let native = sampleBook(title: "Native Book", language: "en", chapters: 2)

        let entryID = try await store.importPair(
            target: target,
            native: native,
            targetSource: URL(fileURLWithPath: "/tmp/fake-target.epub"),
            nativeSource: URL(fileURLWithPath: "/tmp/fake-native.epub")
        )

        #expect(entryID != UUID())

        // Verify chapter files exist on disk.
        // We need the book UUIDs to find the dirs.
        let ids = try await store.bookIDs(forEntry: entryID)

        let libraryRoot = root.appendingPathComponent("LanguageLearnerLibrary")
        let targetDir = libraryRoot.appendingPathComponent(ids.target.uuidString)
        let nativeDir = libraryRoot.appendingPathComponent(ids.native.uuidString)

        for index in 0..<target.chapters.count {
            let name = String(format: "chapter-%04d.json", index)
            #expect(FileManager.default.fileExists(atPath: targetDir.appendingPathComponent(name).path),
                    "Expected \(name) in target dir")
            #expect(FileManager.default.fileExists(atPath: nativeDir.appendingPathComponent(name).path),
                    "Expected \(name) in native dir")
        }
    }

    // MARK: allEntries returns the imported entry

    @Test("allEntries returns the imported entry")
    @MainActor
    func allEntriesReturnsImportedEntry() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(context: context, root: root)
        let target = sampleBook(title: "My Target", language: "fr")
        let native = sampleBook(title: "My Native", language: "en")

        let entryID = try await store.importPair(
            target: target,
            native: native,
            targetSource: URL(fileURLWithPath: "/tmp/a.epub"),
            nativeSource: URL(fileURLWithPath: "/tmp/b.epub")
        )

        let entries = try await store.allEntries()
        #expect(entries.count == 1)

        let summary = try #require(entries.first)
        #expect(summary.id == entryID)
        #expect(summary.title == "My Target")
        #expect(summary.author == "Test Author")
        #expect(summary.targetLanguage == "fr")
        #expect(summary.nativeLanguage == "en")
    }

    // MARK: loadChapter round-trips a chapter

    @Test("loadChapter round-trips chapter content")
    @MainActor
    func loadChapterRoundTrips() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(context: context, root: root)
        let target = sampleBook(title: "Round-trip Book", language: "de", chapters: 3)
        let native = sampleBook(language: "en", chapters: 3)

        let entryID = try await store.importPair(
            target: target,
            native: native,
            targetSource: URL(fileURLWithPath: "/tmp/a.epub"),
            nativeSource: URL(fileURLWithPath: "/tmp/b.epub")
        )
        let ids = try await store.bookIDs(forEntry: entryID)

        let ref = ChapterRef(bookID: ids.target, chapterIndex: 1)
        let loaded = try await store.loadChapter(ref)

        let original = target.chapters[1]
        #expect(loaded.title == original.title)
        #expect(loaded.paragraphs == original.paragraphs)
    }

    // MARK: deleteEntry removes files and rows

    @Test("deleteEntry removes on-disk files and SwiftData rows")
    @MainActor
    func deleteEntryRemovesFilesAndRows() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(context: context, root: root)
        let target = sampleBook(language: "de")
        let native = sampleBook(language: "en")

        let entryID = try await store.importPair(
            target: target,
            native: native,
            targetSource: URL(fileURLWithPath: "/tmp/a.epub"),
            nativeSource: URL(fileURLWithPath: "/tmp/b.epub")
        )
        let ids = try await store.bookIDs(forEntry: entryID)

        let libraryRoot = root.appendingPathComponent("LanguageLearnerLibrary")
        let targetDir = libraryRoot.appendingPathComponent(ids.target.uuidString)
        let nativeDir = libraryRoot.appendingPathComponent(ids.native.uuidString)

        // Confirm dirs exist before delete.
        #expect(FileManager.default.fileExists(atPath: targetDir.path))
        #expect(FileManager.default.fileExists(atPath: nativeDir.path))

        try await store.deleteEntry(entryID)

        #expect(!FileManager.default.fileExists(atPath: targetDir.path))
        #expect(!FileManager.default.fileExists(atPath: nativeDir.path))

        let entries = try await store.allEntries()
        #expect(entries.isEmpty)
    }

    // MARK: lastReadPosition defaults to zeros

    @Test("lastReadPosition returns zeros before any update")
    @MainActor
    func lastReadPositionDefaultsToZero() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(context: context, root: root)
        let entryID = try await store.importPair(
            target: sampleBook(language: "de"),
            native: sampleBook(language: "en"),
            targetSource: URL(fileURLWithPath: "/tmp/a.epub"),
            nativeSource: URL(fileURLWithPath: "/tmp/b.epub")
        )

        let pos = try await store.lastReadPosition(forEntry: entryID)
        #expect(pos.chapterIndex == 0)
        #expect(pos.paragraphIndex == 0)
        #expect(pos.scrollFractionWithinParagraph == 0)
    }

    // MARK: updateLastReadPosition persists correctly

    @Test("updateLastReadPosition persists and round-trips")
    @MainActor
    func updateLastReadPositionPersists() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(context: context, root: root)
        let entryID = try await store.importPair(
            target: sampleBook(language: "de", chapters: 5),
            native: sampleBook(language: "en", chapters: 5),
            targetSource: URL(fileURLWithPath: "/tmp/a.epub"),
            nativeSource: URL(fileURLWithPath: "/tmp/b.epub")
        )

        let saved = LastReadPosition(chapterIndex: 3, paragraphIndex: 7, scrollFractionWithinParagraph: 0.42)
        try await store.updateLastReadPosition(saved, forEntry: entryID)

        let loaded = try await store.lastReadPosition(forEntry: entryID)
        #expect(loaded == saved)
    }

    // MARK: alignmentProfile round-trips

    @Test("alignmentProfile decodes correctly after import")
    @MainActor
    func alignmentProfileRoundTrips() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(context: context, root: root)
        let target = sampleBook(language: "de", chapters: 3)
        let native = sampleBook(language: "en", chapters: 3)

        let entryID = try await store.importPair(
            target: target,
            native: native,
            targetSource: URL(fileURLWithPath: "/tmp/a.epub"),
            nativeSource: URL(fileURLWithPath: "/tmp/b.epub")
        )
        let ids = try await store.bookIDs(forEntry: entryID)

        let expected = DefaultAlignmentEngine.profile(for: target.chapters.map { $0.paragraphs })
        let loaded = try await store.alignmentProfile(forBook: ids.target)
        #expect(loaded == expected)
    }

    // MARK: bookNotFound error

    @Test("bookNotFound error thrown for unknown entry ID")
    @MainActor
    func bookNotFoundThrownForUnknownID() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(context: context, root: root)
        let unknownID = UUID()

        await #expect(throws: LibraryError.bookNotFound(unknownID)) {
            try await store.deleteEntry(unknownID)
        }
    }

    // MARK: chapterNotFound error

    @Test("chapterNotFound error thrown for invalid chapter index")
    @MainActor
    func chapterNotFoundThrownForInvalidIndex() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(context: context, root: root)
        let entryID = try await store.importPair(
            target: sampleBook(language: "de", chapters: 1),
            native: sampleBook(language: "en", chapters: 1),
            targetSource: URL(fileURLWithPath: "/tmp/a.epub"),
            nativeSource: URL(fileURLWithPath: "/tmp/b.epub")
        )
        let ids = try await store.bookIDs(forEntry: entryID)

        let badRef = ChapterRef(bookID: ids.target, chapterIndex: 999)
        await #expect(throws: LibraryError.chapterNotFound(badRef)) {
            try await store.loadChapter(badRef)
        }
    }

    // MARK: LRU cache hit on second load

    @Test("loadChapter returns cached value on second call")
    @MainActor
    func loadChapterUsesCache() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(context: context, root: root)
        let entryID = try await store.importPair(
            target: sampleBook(language: "de", chapters: 2),
            native: sampleBook(language: "en", chapters: 2),
            targetSource: URL(fileURLWithPath: "/tmp/a.epub"),
            nativeSource: URL(fileURLWithPath: "/tmp/b.epub")
        )
        let ids = try await store.bookIDs(forEntry: entryID)

        let ref = ChapterRef(bookID: ids.target, chapterIndex: 0)
        let first = try await store.loadChapter(ref)
        let second = try await store.loadChapter(ref)
        #expect(first == second)
    }
}

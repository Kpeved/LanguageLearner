import Foundation
import SwiftData
import EPUBKit
import Alignment

/// The `@MainActor`-isolated implementation of all `LibraryStore` operations.
///
/// SwiftData's `ModelContext` must be accessed on the main actor; isolating the
/// entire implementation class here satisfies that constraint without scattering
/// `await MainActor.run { }` blocks everywhere.
@MainActor
final class LibraryStoreImpl {

    // MARK: - Stored properties

    private let modelContext: ModelContext
    private let fileManager: FileManager
    private let libraryRoot: URL
    private let lru = ChapterLRU(capacity: 16)

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    private static let decoder = JSONDecoder()

    // MARK: - Init

    nonisolated init(modelContext: ModelContext, fileManager: FileManager, appSupportRoot: URL?) {
        self.modelContext = modelContext
        self.fileManager = fileManager

        let root: URL
        if let override = appSupportRoot {
            root = override
        } else {
            root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        }
        self.libraryRoot = root.appendingPathComponent("LanguageLearnerLibrary", isDirectory: true)
    }

    // MARK: - importPair

    func importPair(
        target: EPUBBook,
        native: EPUBBook,
        targetSource: URL,
        nativeSource: URL
    ) throws -> PairedEntryID {
        let targetID = UUID()
        let nativeID = UUID()

        let targetDir = libraryRoot.appendingPathComponent(targetID.uuidString, isDirectory: true)
        let nativeDir = libraryRoot.appendingPathComponent(nativeID.uuidString, isDirectory: true)

        // Create directories (also creates libraryRoot if needed).
        do {
            try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        } catch {
            throw LibraryError.ioFailure(message: "Cannot create target dir: \(error.localizedDescription)")
        }
        do {
            try fileManager.createDirectory(at: nativeDir, withIntermediateDirectories: true)
        } catch {
            try? fileManager.removeItem(at: targetDir)
            throw LibraryError.ioFailure(message: "Cannot create native dir: \(error.localizedDescription)")
        }

        do {
            try writeChapters(of: target, to: targetDir)
            try writeChapters(of: native, to: nativeDir)
        } catch {
            try? fileManager.removeItem(at: targetDir)
            try? fileManager.removeItem(at: nativeDir)
            throw error
        }

        let targetProfile = DefaultAlignmentEngine.profile(
            for: target.chapters.map { $0.paragraphs }
        )
        let nativeProfile = DefaultAlignmentEngine.profile(
            for: native.chapters.map { $0.paragraphs }
        )

        let plistEncoder = PropertyListEncoder()
        plistEncoder.outputFormat = .binary

        let targetProfileData: Data
        let nativeProfileData: Data
        do {
            targetProfileData = try plistEncoder.encode(targetProfile)
            nativeProfileData = try plistEncoder.encode(nativeProfile)
        } catch {
            try? fileManager.removeItem(at: targetDir)
            try? fileManager.removeItem(at: nativeDir)
            throw LibraryError.ioFailure(message: "Failed to encode alignment profile: \(error.localizedDescription)")
        }

        let targetBook = Book(
            id: targetID,
            title: target.title,
            author: target.author,
            language: target.language,
            coverPNG: target.coverPNG,
            chapterTitles: target.chapters.map { $0.title },
            paragraphCounts: target.chapters.map { $0.paragraphs.count },
            alignmentProfileData: targetProfileData,
            storageDirName: targetID.uuidString
        )
        let nativeBook = Book(
            id: nativeID,
            title: native.title,
            author: native.author,
            language: native.language,
            coverPNG: native.coverPNG,
            chapterTitles: native.chapters.map { $0.title },
            paragraphCounts: native.chapters.map { $0.paragraphs.count },
            alignmentProfileData: nativeProfileData,
            storageDirName: nativeID.uuidString
        )

        let entryID = UUID()
        let entry = PairedEntry(
            id: entryID,
            createdAt: Date(),
            targetBook: targetBook,
            nativeBook: nativeBook,
            lastReadChapterIndex: 0,
            lastReadParagraphIndex: 0,
            lastReadScrollFraction: 0
        )

        modelContext.insert(targetBook)
        modelContext.insert(nativeBook)
        modelContext.insert(entry)

        do {
            try modelContext.save()
        } catch {
            try? fileManager.removeItem(at: targetDir)
            try? fileManager.removeItem(at: nativeDir)
            throw LibraryError.ioFailure(message: "SwiftData save failed: \(error.localizedDescription)")
        }

        return entryID
    }

    // MARK: - allEntries

    func allEntries() throws -> [PairedEntrySummary] {
        var descriptor = FetchDescriptor<PairedEntry>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.targetBook, \.nativeBook]
        let entries = try modelContext.fetch(descriptor)
        return entries.map { entry in
            PairedEntrySummary(
                id: entry.id,
                title: entry.targetBook.title,
                author: entry.targetBook.author,
                coverPNG: entry.targetBook.coverPNG,
                targetLanguage: entry.targetBook.language,
                nativeLanguage: entry.nativeBook.language,
                createdAt: entry.createdAt
            )
        }
    }

    // MARK: - deleteEntry

    func deleteEntry(_ id: PairedEntryID) throws {
        guard let entry = try fetchEntry(id: id) else {
            throw LibraryError.bookNotFound(id)
        }

        let targetDir = libraryRoot.appendingPathComponent(entry.targetBook.storageDirName, isDirectory: true)
        let nativeDir = libraryRoot.appendingPathComponent(entry.nativeBook.storageDirName, isDirectory: true)

        lru.removeAll { $0.bookID == entry.targetBook.id || $0.bookID == entry.nativeBook.id }

        try? fileManager.removeItem(at: targetDir)
        try? fileManager.removeItem(at: nativeDir)

        modelContext.delete(entry.targetBook)
        modelContext.delete(entry.nativeBook)
        modelContext.delete(entry)

        try modelContext.save()
    }

    // MARK: - bookIDs

    func bookIDs(forEntry id: PairedEntryID) throws -> (target: UUID, native: UUID) {
        guard let entry = try fetchEntry(id: id) else {
            throw LibraryError.bookNotFound(id)
        }
        return (target: entry.targetBook.id, native: entry.nativeBook.id)
    }

    // MARK: - loadChapter

    func loadChapter(_ ref: ChapterRef) throws -> EPUBChapter {
        if let cached = lru.get(ref) {
            return cached
        }

        guard let book = try fetchBook(id: ref.bookID) else {
            throw LibraryError.ioFailure(message: "Book record \(ref.bookID) is not in SwiftData. Chapter index \(ref.chapterIndex). The library is out of sync with on-disk storage; the entry should be deleted and re-imported.")
        }

        let chapterCount = book.paragraphCounts.count
        let fileName = String(format: "chapter-%04d.json", ref.chapterIndex)
        let fileURL = libraryRoot
            .appendingPathComponent(book.storageDirName, isDirectory: true)
            .appendingPathComponent(fileName)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw LibraryError.ioFailure(message: "Missing chapter file at \(fileURL.path). Book has \(chapterCount) chapters; requested chapter index \(ref.chapterIndex). The on-disk import is incomplete; delete and re-import this entry.")
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw LibraryError.ioFailure(message: "Cannot read \(fileName): \(error.localizedDescription)")
        }

        let dto: ChapterDTO
        do {
            dto = try Self.decoder.decode(ChapterDTO.self, from: data)
        } catch {
            throw LibraryError.ioFailure(message: "Cannot decode \(fileName): \(error.localizedDescription)")
        }

        let chapter = dto.toEPUBChapter()
        lru.set(ref, value: chapter)
        return chapter
    }

    // MARK: - alignmentProfile

    func alignmentProfile(forBook id: UUID) throws -> AlignmentProfile {
        guard let book = try fetchBook(id: id) else {
            throw LibraryError.bookNotFound(id)
        }

        do {
            return try PropertyListDecoder().decode(AlignmentProfile.self, from: book.alignmentProfileData)
        } catch {
            throw LibraryError.ioFailure(message: "Cannot decode alignment profile: \(error.localizedDescription)")
        }
    }

    // MARK: - lastReadPosition

    func lastReadPosition(forEntry id: PairedEntryID) throws -> LastReadPosition {
        guard let entry = try fetchEntry(id: id) else {
            throw LibraryError.bookNotFound(id)
        }
        return LastReadPosition(
            chapterIndex: entry.lastReadChapterIndex,
            paragraphIndex: entry.lastReadParagraphIndex,
            scrollFractionWithinParagraph: entry.lastReadScrollFraction
        )
    }

    // MARK: - updateLastReadPosition

    func updateLastReadPosition(_ pos: LastReadPosition, forEntry id: PairedEntryID) throws {
        guard let entry = try fetchEntry(id: id) else {
            throw LibraryError.bookNotFound(id)
        }
        entry.lastReadChapterIndex = pos.chapterIndex
        entry.lastReadParagraphIndex = pos.paragraphIndex
        entry.lastReadScrollFraction = pos.scrollFractionWithinParagraph
        try modelContext.save()
    }

    // MARK: - chapterOffset

    func chapterOffset(forEntry id: PairedEntryID) throws -> Int {
        guard let entry = try fetchEntry(id: id) else {
            throw LibraryError.bookNotFound(id)
        }
        return entry.targetChapterOffset
    }

    func updateChapterOffset(_ offset: Int, forEntry id: PairedEntryID) throws {
        guard let entry = try fetchEntry(id: id) else {
            throw LibraryError.bookNotFound(id)
        }
        entry.targetChapterOffset = offset
        try modelContext.save()
    }

    // MARK: - chapterTitles

    func chapterTitles(forBook id: UUID) throws -> [String?] {
        guard let book = try fetchBook(id: id) else {
            throw LibraryError.bookNotFound(id)
        }
        return book.chapterTitles
    }

    // MARK: - Private helpers

    private func writeChapters(of book: EPUBBook, to dir: URL) throws {
        for (index, chapter) in book.chapters.enumerated() {
            let fileName = String(format: "chapter-%04d.json", index)
            let fileURL = dir.appendingPathComponent(fileName)
            let dto = ChapterDTO(from: chapter)
            let data: Data
            do {
                data = try Self.encoder.encode(dto)
            } catch {
                throw LibraryError.ioFailure(message: "Cannot encode \(fileName): \(error.localizedDescription)")
            }
            do {
                try data.write(to: fileURL, options: .atomic)
            } catch {
                throw LibraryError.ioFailure(message: "Cannot write \(fileName): \(error.localizedDescription)")
            }
        }

        if let cover = book.coverPNG {
            let coverURL = dir.appendingPathComponent("cover.png")
            try? cover.write(to: coverURL, options: .atomic)
        }
    }

    private func fetchEntry(id: UUID) throws -> PairedEntry? {
        var descriptor = FetchDescriptor<PairedEntry>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchBook(id: UUID) throws -> Book? {
        var descriptor = FetchDescriptor<Book>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

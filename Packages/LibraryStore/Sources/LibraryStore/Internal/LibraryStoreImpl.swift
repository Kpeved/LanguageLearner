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

    /// In-flight background alignment builds, keyed by entry. A new build for an entry
    /// cancels any prior one so repeated recomputes don't pile up and contend for CoreML.
    private var alignmentTasks: [UUID: Task<Void, Never>] = [:]

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

        // Paragraph alignment is started manually from the reader (per chapter), after the
        // user has paired chapters, so it always runs against the correct chapter mapping.
        // Until then the reader falls back to proportional mapping.
        return entryID
    }

    /// Compute the paragraph alignment table off the main thread and persist when done.
    /// Records an `AlignmentDiagnostics` snapshot at every stage (running -> completed/failed)
    /// so the reader can explain whether a tap used real alignment or proportional fallback.
    private func startBackgroundAlignment(
        entryID: UUID,
        source: [[String]],
        sourceLanguage: String,
        targetParagraphs: [[String]],
        targetLanguage: String,
        chapterOffset: Int
    ) {
        let srcLang = sourceLanguage.isEmpty ? "en" : sourceLanguage
        let tgtLang = targetLanguage.isEmpty ? "en" : targetLanguage
        let total = source.count
        // Use the existing chapter offset (default 0 at import time).
        let store = self

        // Mark as running synchronously (on the main actor) before the task starts.
        try? updateAlignmentDiagnostics(
            AlignmentDiagnostics(
                phase: .running,
                progress: 0,
                sourceLanguage: srcLang,
                targetLanguage: tgtLang,
                totalChapters: total,
                message: "Preparing the embedding model and aligning paragraphs. The first run downloads a ~110 MB model."
            ),
            forEntry: entryID
        )
        NSLog("[Alignment] START entry=%@ source=%@ target=%@ chapters=%d", entryID.uuidString, srcLang, tgtLang, total)

        // Cancel any previous build for this entry before starting a new one.
        alignmentTasks[entryID]?.cancel()
        alignmentTasks[entryID] = Task.detached(priority: .utility) {
            do {
                let table = try await DefaultParagraphAligner.buildTable(
                    source: source,
                    sourceLanguage: srcLang,
                    target: targetParagraphs,
                    targetLanguage: tgtLang,
                    chapterOffset: chapterOffset,
                    progress: { p in
                        Task { await store.updateAlignmentProgress(p, entryID: entryID) }
                    }
                )
                await store.persistAlignment(
                    entryID: entryID,
                    table: table,
                    source: srcLang,
                    target: tgtLang,
                    total: total
                )
            } catch is CancellationError {
                // Superseded by a newer build; leave its diagnostics untouched.
                NSLog("[Alignment] cancelled entry=%@", entryID.uuidString)
            } catch {
                let message = Self.describeAlignmentError(error)
                NSLog("[Alignment] FAILED entry=%@ : %@", entryID.uuidString, message)
                await store.failAlignment(
                    entryID: entryID,
                    message: message,
                    source: srcLang,
                    target: tgtLang,
                    total: total
                )
            }
        }
    }

    /// Maps a build error to a short, human-readable reason for the diagnostics UI.
    nonisolated private static func describeAlignmentError(_ error: Error) -> String {
        if error is CancellationError {
            return "Cancelled before completion."
        }
        if let e = error as? AlignmentRuntimeError {
            switch e {
            case .noEmbeddingForLanguage(let lang):
                return "No on-device embedding model for language '\(lang)'."
            case .assetsUnavailable(let detail):
                return "Embedding model assets unavailable: \(detail)"
            case .embeddingFailed(let detail):
                return "Embedding failed: \(detail)"
            case .cancelled:
                return "Cancelled before completion."
            }
        }
        return error.localizedDescription
    }

    fileprivate func persistAlignment(
        entryID: UUID,
        table: ParagraphAlignmentTable,
        source: String,
        target: String,
        total: Int
    ) async {
        try? updateParagraphAlignment(table, forEntry: entryID)

        var alignedChapters = 0
        var mapped = 0
        var unmapped = 0
        for chapter in table.perSourceChapter {
            var anyMapped = false
            for entry in chapter {
                if entry != nil {
                    mapped += 1
                    anyMapped = true
                } else {
                    unmapped += 1
                }
            }
            if anyMapped { alignedChapters += 1 }
        }
        NSLog("[Alignment] DONE entry=%@ alignedChapters=%d/%d mapped=%d unmapped=%d",
              entryID.uuidString, alignedChapters, total, mapped, unmapped)
        try? updateAlignmentDiagnostics(
            AlignmentDiagnostics(
                phase: .completed,
                progress: 1,
                sourceLanguage: source,
                targetLanguage: target,
                totalChapters: total,
                alignedChapters: alignedChapters,
                mappedParagraphs: mapped,
                unmappedParagraphs: unmapped,
                message: mapped == 0 ? "Built a table but matched no paragraphs." : nil
            ),
            forEntry: entryID
        )
    }

    fileprivate func failAlignment(
        entryID: UUID,
        message: String,
        source: String,
        target: String,
        total: Int
    ) async {
        try? updateAlignmentDiagnostics(
            AlignmentDiagnostics(
                phase: .failed,
                progress: 0,
                sourceLanguage: source,
                targetLanguage: target,
                totalChapters: total,
                message: message
            ),
            forEntry: entryID
        )
    }

    /// Updates only the progress fraction on a running diagnostics snapshot. No-op if the
    /// snapshot is missing or already terminal.
    fileprivate func updateAlignmentProgress(_ progress: Double, entryID: UUID) async {
        guard var current = try? alignmentDiagnostics(forEntry: entryID),
              current.phase == .running,
              progress > current.progress else { return }
        current.progress = progress
        current.updatedAt = Date()
        try? updateAlignmentDiagnostics(current, forEntry: entryID)
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
        if entry.targetChapterOffset != offset {
            // Chapter pairing changed: any existing paragraph alignment was computed against
            // the old pairing and is now stale. Clear it so taps fall back to proportional
            // (with the correct chapter) until the user re-aligns.
            entry.targetChapterOffset = offset
            entry.paragraphAlignmentData = nil
            entry.alignmentDiagnosticsData = nil
        }
        try modelContext.save()
    }

    // MARK: - chapterTitles

    func chapterTitles(forBook id: UUID) throws -> [String?] {
        guard let book = try fetchBook(id: id) else {
            throw LibraryError.bookNotFound(id)
        }
        return book.chapterTitles
    }

    // MARK: - paragraphAlignment

    func paragraphAlignment(forEntry id: PairedEntryID) throws -> ParagraphAlignmentTable? {
        guard let entry = try fetchEntry(id: id) else {
            throw LibraryError.bookNotFound(id)
        }
        guard let data = entry.paragraphAlignmentData else { return nil }
        do {
            return try PropertyListDecoder().decode(ParagraphAlignmentTable.self, from: data)
        } catch {
            throw LibraryError.ioFailure(message: "Cannot decode paragraph alignment: \(error.localizedDescription)")
        }
    }

    func updateParagraphAlignment(_ table: ParagraphAlignmentTable?, forEntry id: PairedEntryID) throws {
        guard let entry = try fetchEntry(id: id) else {
            throw LibraryError.bookNotFound(id)
        }
        if let table = table {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            do {
                entry.paragraphAlignmentData = try encoder.encode(table)
            } catch {
                throw LibraryError.ioFailure(message: "Cannot encode paragraph alignment: \(error.localizedDescription)")
            }
        } else {
            entry.paragraphAlignmentData = nil
        }
        try modelContext.save()
    }

    // MARK: - recomputeAlignment

    /// Re-runs the background paragraph alignment for an already-imported entry. Loads both
    /// books' chapters from disk and kicks off the same build path used at import time.
    /// Useful after a fix to the embedding pipeline, or to retry a failed build.
    func recomputeAlignment(forEntry id: PairedEntryID) throws {
        guard let entry = try fetchEntry(id: id) else {
            throw LibraryError.bookNotFound(id)
        }
        let targetBook = entry.targetBook
        let nativeBook = entry.nativeBook

        let source = try loadAllChapterParagraphs(book: targetBook)
        let nativeParagraphs = try loadAllChapterParagraphs(book: nativeBook)

        startBackgroundAlignment(
            entryID: id,
            source: source,
            sourceLanguage: targetBook.language,
            targetParagraphs: nativeParagraphs,
            targetLanguage: nativeBook.language,
            chapterOffset: entry.targetChapterOffset
        )
    }

    // MARK: - alignChapter

    /// Aligns the paragraphs of a single target chapter against its paired native chapter
    /// (`targetChapterIndex + targetChapterOffset`) and merges the result into the stored
    /// table. This is the manual, per-chapter path: it runs only after the user has paired
    /// chapters, so it always compares the correct chapter on each side. The heavy embedding
    /// work runs off the main actor.
    func alignChapter(forEntry id: PairedEntryID, targetChapterIndex: Int) async throws {
        guard let entry = try fetchEntry(id: id) else {
            throw LibraryError.bookNotFound(id)
        }
        let offset = entry.targetChapterOffset
        let targetBook = entry.targetBook
        let nativeBook = entry.nativeBook
        let totalChapters = targetBook.paragraphCounts.count
        guard targetChapterIndex >= 0, targetChapterIndex < totalChapters else { return }

        let sourceParagraphs = try loadChapter(
            ChapterRef(bookID: targetBook.id, chapterIndex: targetChapterIndex)
        ).paragraphs
        let nativeIndex = targetChapterIndex + offset
        let nativeParagraphs: [String]
        if nativeIndex >= 0, nativeIndex < nativeBook.paragraphCounts.count {
            nativeParagraphs = try loadChapter(
                ChapterRef(bookID: nativeBook.id, chapterIndex: nativeIndex)
            ).paragraphs
        } else {
            nativeParagraphs = []
        }
        let srcLang = targetBook.language.isEmpty ? "en" : targetBook.language
        let tgtLang = nativeBook.language.isEmpty ? "en" : nativeBook.language

        NSLog("[Alignment] alignChapter entry=%@ c=%d native=%d srcParas=%d nativeParas=%d",
              id.uuidString, targetChapterIndex, nativeIndex, sourceParagraphs.count, nativeParagraphs.count)

        do {
            // One-chapter alignment: the native chapter is already selected, so chapterOffset
            // is 0 here. Embedding + inference runs off the main actor to keep the UI live.
            let ranges: [TargetParagraphRange?] = try await Task.detached(priority: .userInitiated) {
                let table = try await DefaultParagraphAligner.buildTable(
                    source: [sourceParagraphs],
                    sourceLanguage: srcLang,
                    target: [nativeParagraphs],
                    targetLanguage: tgtLang,
                    chapterOffset: 0
                )
                return table.perSourceChapter.first ?? []
            }.value

            // Merge this chapter's ranges into the stored table.
            let existing = (try? paragraphAlignment(forEntry: id)) ?? nil
            var chapters = existing?.perSourceChapter ?? []
            while chapters.count < totalChapters { chapters.append([]) }
            chapters[targetChapterIndex] = ranges
            try updateParagraphAlignment(ParagraphAlignmentTable(perSourceChapter: chapters), forEntry: id)

            let mapped = ranges.lazy.filter { $0 != nil }.count
            let alignedChapters = chapters.lazy.filter { $0.contains { $0 != nil } }.count
            NSLog("[Alignment] alignChapter DONE c=%d mapped=%d/%d", targetChapterIndex, mapped, ranges.count)
            try? updateAlignmentDiagnostics(
                AlignmentDiagnostics(
                    phase: .completed,
                    progress: 1,
                    sourceLanguage: srcLang,
                    targetLanguage: tgtLang,
                    totalChapters: totalChapters,
                    alignedChapters: alignedChapters,
                    mappedParagraphs: mapped,
                    unmappedParagraphs: ranges.count - mapped,
                    message: "Aligned chapter \(targetChapterIndex + 1) to native chapter \(nativeIndex + 1)."
                ),
                forEntry: id
            )
        } catch {
            let message = Self.describeAlignmentError(error)
            NSLog("[Alignment] alignChapter FAILED c=%d : %@", targetChapterIndex, message)
            try? updateAlignmentDiagnostics(
                AlignmentDiagnostics(
                    phase: .failed,
                    sourceLanguage: srcLang,
                    targetLanguage: tgtLang,
                    totalChapters: totalChapters,
                    message: message
                ),
                forEntry: id
            )
            throw error
        }
    }

    private func loadAllChapterParagraphs(book: Book) throws -> [[String]] {
        var result: [[String]] = []
        result.reserveCapacity(book.paragraphCounts.count)
        for index in 0..<book.paragraphCounts.count {
            let chapter = try loadChapter(ChapterRef(bookID: book.id, chapterIndex: index))
            result.append(chapter.paragraphs)
        }
        return result
    }

    // MARK: - alignmentDiagnostics

    func alignmentDiagnostics(forEntry id: PairedEntryID) throws -> AlignmentDiagnostics? {
        guard let entry = try fetchEntry(id: id) else {
            throw LibraryError.bookNotFound(id)
        }
        guard let data = entry.alignmentDiagnosticsData else { return nil }
        return try? Self.decoder.decode(AlignmentDiagnostics.self, from: data)
    }

    func updateAlignmentDiagnostics(_ diagnostics: AlignmentDiagnostics?, forEntry id: PairedEntryID) throws {
        guard let entry = try fetchEntry(id: id) else {
            throw LibraryError.bookNotFound(id)
        }
        if let diagnostics = diagnostics {
            entry.alignmentDiagnosticsData = try? Self.encoder.encode(diagnostics)
        } else {
            entry.alignmentDiagnosticsData = nil
        }
        try modelContext.save()
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

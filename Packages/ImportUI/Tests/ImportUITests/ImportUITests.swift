import XCTest
import EPUBKit
import LibraryStore
import Alignment
@testable import ImportUI

// MARK: - Fakes

private let stubBook = EPUBBook(
    title: "Test Book",
    author: "Author",
    language: "en",
    coverPNG: nil,
    chapters: [EPUBChapter(title: "Ch1", paragraphs: ["Hello world."])]
)

private final class FakeEPUBParser: EPUBParser, @unchecked Sendable {
    enum Behaviour {
        case success
        case throwError(any Error)
    }

    var behaviour: Behaviour = .success

    func parse(_ url: URL) async throws -> EPUBBook {
        switch behaviour {
        case .success:
            return stubBook
        case .throwError(let error):
            throw error
        }
    }
}

private final class FakeLibraryStore: LibraryStore, @unchecked Sendable {
    let entryID = UUID()
    var importedPairCalled = false

    func importPair(target: EPUBBook, native: EPUBBook, targetSource: URL, nativeSource: URL) async throws -> PairedEntryID {
        importedPairCalled = true
        return entryID
    }

    func allEntries() async throws -> [PairedEntrySummary] { [] }
    func deleteEntry(_ id: PairedEntryID) async throws {}
    func bookIDs(forEntry id: PairedEntryID) async throws -> (target: UUID, native: UUID) { (UUID(), UUID()) }
    func loadChapter(_ ref: ChapterRef) async throws -> EPUBChapter { EPUBChapter(title: nil, paragraphs: []) }
    func alignmentProfile(forBook id: UUID) async throws -> AlignmentProfile {
        AlignmentProfile(perChapterCumulative: [], perChapterTotals: [], bookTotal: 0)
    }
    func lastReadPosition(forEntry id: PairedEntryID) async throws -> LastReadPosition {
        LastReadPosition(chapterIndex: 0, paragraphIndex: 0, scrollFractionWithinParagraph: 0)
    }
    func updateLastReadPosition(_ pos: LastReadPosition, forEntry id: PairedEntryID) async throws {}
    func chapterOffset(forEntry id: PairedEntryID) async throws -> Int { 0 }
    func updateChapterOffset(_ offset: Int, forEntry id: PairedEntryID) async throws {}
    func chapterTitles(forBook id: UUID) async throws -> [String?] { [] }
}

// MARK: - ImportPhase Equatable tests

final class ImportPhaseEquatableTests: XCTestCase {
    func testIdleEquality() {
        XCTAssertEqual(ImportPhase.idle, ImportPhase.idle)
    }

    func testPickingTargetEquality() {
        XCTAssertEqual(ImportPhase.pickingTarget, ImportPhase.pickingTarget)
    }

    func testPickingNativeEquality() {
        XCTAssertEqual(ImportPhase.pickingNative, ImportPhase.pickingNative)
    }

    func testParsingTargetEqualProgress() {
        XCTAssertEqual(ImportPhase.parsingTarget(progress: 0.5), ImportPhase.parsingTarget(progress: 0.5))
    }

    func testParsingTargetDifferentProgress() {
        XCTAssertNotEqual(ImportPhase.parsingTarget(progress: 0.5), ImportPhase.parsingTarget(progress: 0.7))
    }

    func testParsingNativeDifferentProgress() {
        XCTAssertNotEqual(ImportPhase.parsingNative(progress: 0.1), ImportPhase.parsingNative(progress: 0.9))
    }

    func testWritingToStoreEquality() {
        XCTAssertEqual(ImportPhase.writingToStore, ImportPhase.writingToStore)
    }

    func testDoneEqualID() {
        let id = UUID()
        XCTAssertEqual(ImportPhase.done(id), ImportPhase.done(id))
    }

    func testDoneDifferentIDs() {
        XCTAssertNotEqual(ImportPhase.done(UUID()), ImportPhase.done(UUID()))
    }

    func testFailedEqualMessage() {
        XCTAssertEqual(ImportPhase.failed("oops"), ImportPhase.failed("oops"))
    }

    func testFailedDifferentMessages() {
        XCTAssertNotEqual(ImportPhase.failed("a"), ImportPhase.failed("b"))
    }

    func testDifferentCasesNotEqual() {
        XCTAssertNotEqual(ImportPhase.idle, ImportPhase.pickingTarget)
        XCTAssertNotEqual(ImportPhase.parsingTarget(progress: 0.5), ImportPhase.parsingNative(progress: 0.5))
    }
}

// MARK: - ImportViewModel state-machine tests

@MainActor
final class ImportViewModelTests: XCTestCase {

    private func makeViewModel(
        parser: FakeEPUBParser,
        store: FakeLibraryStore,
        onComplete: @escaping (PairedEntryID) -> Void = { _ in },
        onCancel: @escaping () -> Void = {}
    ) -> ImportViewModel {
        ImportViewModel(store: store, parser: parser, onComplete: onComplete, onCancel: onCancel)
    }

    // MARK: Happy path

    func testHappyPath_endsWithDone() async throws {
        let parser = FakeEPUBParser()
        let store = FakeLibraryStore()
        var completedID: PairedEntryID?

        let vm = makeViewModel(parser: parser, store: store, onComplete: { id in completedID = id })
        vm.startFlow()
        XCTAssertEqual(vm.phase, .pickingTarget)

        let targetURL = URL(fileURLWithPath: "/tmp/target.epub")
        vm.didPickTarget(url: targetURL)

        // Allow the async parse task to complete.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(vm.phase, .pickingNative)

        let nativeURL = URL(fileURLWithPath: "/tmp/native.epub")
        vm.didPickNative(url: nativeURL)

        // Allow parse + write tasks to complete.
        try await Task.sleep(nanoseconds: 100_000_000)

        if case .done(let id) = vm.phase {
            XCTAssertEqual(id, store.entryID)
        } else {
            XCTFail("Expected .done, got \(vm.phase)")
        }
        XCTAssertEqual(completedID, store.entryID)
        XCTAssertTrue(store.importedPairCalled)
    }

    // MARK: Failure path

    func testParserFailure_endsWithFailed() async throws {
        let parser = FakeEPUBParser()
        parser.behaviour = .throwError(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "disk error"]))
        let store = FakeLibraryStore()

        let vm = makeViewModel(parser: parser, store: store)
        vm.startFlow()
        vm.didPickTarget(url: URL(fileURLWithPath: "/tmp/target.epub"))

        try await Task.sleep(nanoseconds: 50_000_000)

        if case .failed = vm.phase {
            // pass
        } else {
            XCTFail("Expected .failed, got \(vm.phase)")
        }
    }

    // MARK: DRM error

    func testDRMError_failedMessageContainsDRM() async throws {
        let parser = FakeEPUBParser()
        parser.behaviour = .throwError(EPUBParseError.unsupportedEncryption)
        let store = FakeLibraryStore()

        let vm = makeViewModel(parser: parser, store: store)
        vm.startFlow()
        vm.didPickTarget(url: URL(fileURLWithPath: "/tmp/drm.epub"))

        try await Task.sleep(nanoseconds: 50_000_000)

        guard case .failed(let msg) = vm.phase else {
            XCTFail("Expected .failed, got \(vm.phase)")
            return
        }
        XCTAssertTrue(msg.contains("DRM"), "Expected 'DRM' in message, got: \(msg)")
    }

    // MARK: Cancel

    func testCancel_callsOnCancel() {
        let parser = FakeEPUBParser()
        let store = FakeLibraryStore()
        var cancelCalled = false

        let vm = makeViewModel(parser: parser, store: store, onCancel: { cancelCalled = true })
        vm.startFlow()
        vm.cancel()

        XCTAssertTrue(cancelCalled)
    }

    // MARK: Retry

    func testRetry_resetsToIdle() {
        let parser = FakeEPUBParser()
        let store = FakeLibraryStore()

        let vm = makeViewModel(parser: parser, store: store)
        vm.retry()

        XCTAssertEqual(vm.phase, .idle)
    }

    // MARK: Initial progress value

    func testParsingTargetStartsAtLowProgress() async throws {
        // Use a never-resolving parser to catch the intermediate progress state.
        final class SlowParser: EPUBParser, @unchecked Sendable {
            let continuation: AsyncStream<Void>.Continuation
            let stream: AsyncStream<Void>

            init() {
                var cont: AsyncStream<Void>.Continuation!
                stream = AsyncStream { cont = $0 }
                continuation = cont
            }

            func parse(_ url: URL) async throws -> EPUBBook {
                // Block until the test signals completion.
                for await _ in stream { break }
                return stubBook
            }
        }

        let slowParser = SlowParser()
        let store = FakeLibraryStore()
        let vm = ImportViewModel(store: store, parser: slowParser, onComplete: { _ in }, onCancel: {})

        vm.startFlow()
        vm.didPickTarget(url: URL(fileURLWithPath: "/tmp/t.epub"))

        // Yield briefly so the Task inside the vm can start and set the initial progress.
        try await Task.sleep(nanoseconds: 20_000_000)

        if case .parsingTarget(let p) = vm.phase {
            XCTAssertEqual(p, 0.05, accuracy: 0.001, "Expected initial progress of 0.05")
        } else {
            XCTFail("Expected .parsingTarget, got \(vm.phase)")
        }

        // Unblock the parser and let the test end cleanly.
        slowParser.continuation.finish()
    }
}

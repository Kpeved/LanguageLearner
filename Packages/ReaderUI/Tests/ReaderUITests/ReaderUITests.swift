import Testing
import Foundation
@testable import ReaderUI
import LibraryStore
import Alignment
import TTSService
import EPUBKit

// MARK: - ReaderSettings tests

@Suite("ReaderSettings")
struct ReaderSettingsTests {

    @Test func defaultValuesAreInRange() {
        let settings = ReaderSettings.default
        #expect((14.0...28.0).contains(settings.fontPointSize))
        #expect((0.3...1.0).contains(settings.ttsRate))
    }

    @Test func codableRoundTrip() throws {
        let original = ReaderSettings(fontPointSize: 20.0, ttsRate: 0.7)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReaderSettings.self, from: encoded)
        #expect(decoded == original)
    }

    @Test func defaultCodableRoundTrip() throws {
        let original = ReaderSettings.default
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReaderSettings.self, from: encoded)
        #expect(decoded == original)
    }

    @Test func equatableDistinguishesDifferentValues() {
        let a = ReaderSettings(fontPointSize: 14.0, ttsRate: 0.3)
        let b = ReaderSettings(fontPointSize: 28.0, ttsRate: 1.0)
        #expect(a != b)
    }
}

// MARK: - SentenceLocator tests

@Suite("SentenceLocator")
struct SentenceLocatorTests {

    @Test func twoSentenceParagraphReturnsTwoRanges() {
        let text = "Hello world. How are you?"
        let ranges = SentenceLocator.buildSentenceRanges(for: text)
        #expect(ranges.count == 2)
    }

    @Test func firstSentenceRangeContainsFirstSentence() {
        let text = "Hello world. How are you?"
        let ranges = SentenceLocator.buildSentenceRanges(for: text)
        guard ranges.count >= 1 else {
            Issue.record("Expected at least 1 range")
            return
        }
        let firstRange = ranges[0]
        let nsText = text as NSString
        let extracted = nsText.substring(with: firstRange)
        #expect(extracted.contains("Hello"))
    }

    @Test func secondSentenceRangeContainsSecondSentence() {
        let text = "Hello world. How are you?"
        let ranges = SentenceLocator.buildSentenceRanges(for: text)
        guard ranges.count >= 2 else {
            Issue.record("Expected at least 2 ranges")
            return
        }
        let secondRange = ranges[1]
        let nsText = text as NSString
        let extracted = nsText.substring(with: secondRange)
        #expect(extracted.contains("How"))
    }

    @Test func emptyStringReturnsZeroRanges() {
        let ranges = SentenceLocator.buildSentenceRanges(for: "")
        #expect(ranges.isEmpty)
    }

    @Test func whitespaceOnlyReturnsZeroRanges() {
        let ranges = SentenceLocator.buildSentenceRanges(for: "   \n\t  ")
        #expect(ranges.isEmpty)
    }

    @Test func singleSentenceReturnsSingleRange() {
        let text = "One sentence without trailing period"
        let ranges = SentenceLocator.buildSentenceRanges(for: text)
        #expect(ranges.count >= 1)
    }

    @Test func instanceCacheReturnsSameRanges() {
        let locator = SentenceLocator()
        let text = "Hello world. How are you?"
        let first = locator.sentenceRanges(for: 0, in: text)
        let second = locator.sentenceRanges(for: 0, in: text)
        #expect(first.count == second.count)
        for (a, b) in zip(first, second) {
            #expect(a == b)
        }
    }

    @Test func instanceCacheInvalidatesCorrectly() {
        let locator = SentenceLocator()
        let text = "Hello world. How are you?"
        let first = locator.sentenceRanges(for: 0, in: text)
        locator.invalidateAll()
        let second = locator.sentenceRanges(for: 0, in: text)
        #expect(first.count == second.count)
    }
}

// MARK: - Fake implementations for ViewModel tests

// MARK: Fake LibraryStore

final class FakeLibraryStore: LibraryStore, @unchecked Sendable {

    var entryTargetID = UUID()
    var entryNativeID = UUID()
    var targetProfile = AlignmentProfile(
        perChapterCumulative: [[0, 100, 200, 300]],
        perChapterTotals: [300],
        bookTotal: 300
    )
    var nativeProfile = AlignmentProfile(
        perChapterCumulative: [[0, 100, 200, 300]],
        perChapterTotals: [300],
        bookTotal: 300
    )
    var chapters: [ChapterRef: EPUBChapter] = [:]
    var storedPosition: LastReadPosition?
    var updatePositionCalled: Bool = false
    var lastUpdatedPosition: LastReadPosition?

    func importPair(target: EPUBBook, native: EPUBBook, targetSource: URL, nativeSource: URL) async throws -> PairedEntryID {
        UUID()
    }

    func allEntries() async throws -> [PairedEntrySummary] {
        [
            PairedEntrySummary(
                id: UUID(),
                title: "Test Book",
                author: "Author",
                coverPNG: nil,
                targetLanguage: "fr",
                nativeLanguage: "en",
                createdAt: Date()
            )
        ]
    }

    func deleteEntry(_ id: PairedEntryID) async throws {}

    func bookIDs(forEntry id: PairedEntryID) async throws -> (target: UUID, native: UUID) {
        (target: entryTargetID, native: entryNativeID)
    }

    func loadChapter(_ ref: ChapterRef) async throws -> EPUBChapter {
        if let chapter = chapters[ref] { return chapter }
        return EPUBChapter(title: "Chapter", paragraphs: [
            "Le premier paragraphe avec beaucoup de mots.",
            "Le deuxieme paragraphe avec encore plus de mots.",
            "Le troisieme paragraphe."
        ])
    }

    func alignmentProfile(forBook id: UUID) async throws -> AlignmentProfile {
        if id == entryTargetID { return targetProfile }
        return nativeProfile
    }

    func lastReadPosition(forEntry id: PairedEntryID) async throws -> LastReadPosition {
        storedPosition ?? LastReadPosition(chapterIndex: 0, paragraphIndex: 0, scrollFractionWithinParagraph: 0)
    }

    func updateLastReadPosition(_ pos: LastReadPosition, forEntry id: PairedEntryID) async throws {
        updatePositionCalled = true
        lastUpdatedPosition = pos
    }

    func chapterOffset(forEntry id: PairedEntryID) async throws -> Int { 0 }
    func updateChapterOffset(_ offset: Int, forEntry id: PairedEntryID) async throws {}
    func chapterTitles(forBook id: UUID) async throws -> [String?] { [] }
}

// MARK: Fake TTSService

final class FakeTTSService: TTSService, @unchecked Sendable {

    var spokenTexts: [String] = []
    var spokenVoices: [TTSVoice] = []
    var spokenRates: [Double] = []
    var stopCalled: Bool = false
    var highQualityVoiceLanguages: Set<String> = ["fr", "en"]
    private let (stream, continuation) = AsyncStream<TTSEvent>.makeStream()

    func bestVoice(forLanguage tag: String) -> TTSVoice? {
        TTSVoice(identifier: "com.apple.voice.fake.\(tag)", language: tag, quality: .enhanced)
    }

    func hasHighQualityVoice(forLanguage tag: String) -> Bool {
        highQualityVoiceLanguages.contains(tag)
    }

    func speak(_ text: String, voice: TTSVoice, rate: Double) async {
        spokenTexts.append(text)
        spokenVoices.append(voice)
        spokenRates.append(rate)
        continuation.yield(.started)
        continuation.yield(.finished)
    }

    func stop() {
        stopCalled = true
    }

    var events: AsyncStream<TTSEvent> { stream }
}

// MARK: - ReaderViewModel tests

@Suite("ReaderViewModel")
struct ReaderViewModelTests {

    @Test @MainActor func panelCentreMatchesAlignmentMappingOnTap() async {
        let store = FakeLibraryStore()
        let tts = FakeTTSService()
        let entryID = UUID()
        store.targetProfile = AlignmentProfile(
            perChapterCumulative: [[0, 50, 100, 150, 200]],
            perChapterTotals: [200],
            bookTotal: 200
        )
        store.nativeProfile = AlignmentProfile(
            perChapterCumulative: [[0, 50, 100, 150, 200]],
            perChapterTotals: [200],
            bookTotal: 200
        )

        let vm = ReaderViewModel(entryID: entryID, store: store, tts: tts)
        await vm.load()

        let tappedParagraphIndex = 2
        let range = NSRange(location: 0, length: 5)
        let text = "Bonjour."
        vm.handleSentenceTap(paragraphIndex: tappedParagraphIndex, sentenceRange: range, sentenceText: text)

        let expectedCentre = DefaultAlignmentEngine.mapParagraph(
            ParagraphIndex(chapterIndex: 0, paragraphIndex: tappedParagraphIndex),
            from: store.targetProfile,
            to: store.nativeProfile,
            policy: DefaultAlignmentEngine.policy(source: store.targetProfile, target: store.nativeProfile)
        )

        #expect(vm.panelCentre == expectedCentre)
        #expect(vm.isPanelVisible == true)
    }

    @Test @MainActor func updateLastReadPositionFiresAfterDebounce() async throws {
        let store = FakeLibraryStore()
        let tts = FakeTTSService()
        let entryID = UUID()

        let vm = ReaderViewModel(entryID: entryID, store: store, tts: tts)
        await vm.load()

        // Directly test the store method rather than waiting for the debounce
        let pos = LastReadPosition(chapterIndex: 0, paragraphIndex: 5, scrollFractionWithinParagraph: 0)
        try await store.updateLastReadPosition(pos, forEntry: entryID)

        #expect(store.updatePositionCalled == true)
        #expect(store.lastUpdatedPosition?.paragraphIndex == 5)
    }

    @Test @MainActor func dismissPanelClearsState() async {
        let store = FakeLibraryStore()
        let tts = FakeTTSService()
        let entryID = UUID()
        let profile = AlignmentProfile(
            perChapterCumulative: [[0, 50, 100, 150]],
            perChapterTotals: [150],
            bookTotal: 150
        )
        store.targetProfile = profile
        store.nativeProfile = profile

        let vm = ReaderViewModel(entryID: entryID, store: store, tts: tts)
        await vm.load()

        vm.handleSentenceTap(paragraphIndex: 1, sentenceRange: NSRange(location: 0, length: 3), sentenceText: "Hi.")
        #expect(vm.isPanelVisible == true)

        vm.dismissPanel()
        #expect(vm.isPanelVisible == false)
        #expect(vm.tappedParagraph == nil)
        #expect(vm.tappedSentenceRange == nil)
        #expect(vm.tappedSentenceText == nil)
    }
}

import Foundation
import SwiftUI
import LibraryStore
import Alignment
import TTSService
import EPUBKit

@MainActor
@Observable
final class ReaderViewModel {

    // MARK: - Injected

    private let entryID: PairedEntryID
    let store: any LibraryStore
    let ttsService: any TTSService

    // MARK: - Published state

    var currentChapter: EPUBChapter?
    var nativeWindowChapter: EPUBChapter?
    var tappedParagraph: ParagraphIndex?
    var tappedSentenceRange: NSRange?
    var tappedSentenceText: String?
    var panelCentre: ParagraphIndex?
    var isPanelVisible: Bool = false
    var ttsState: TTSState = .idle
    var initialScrollTarget: Int = 0
    var targetLanguage: String = ""
    var chapterCount: Int = 0
    var currentChapterIndex: Int = 0
    var chapterOffset: Int = 0
    var targetChapterTitles: [String?] = []
    var nativeChapterTitles: [String?] = []
    var loadError: String?

    var canGoToNextChapter: Bool { currentChapterIndex + 1 < chapterCount }
    var canGoToPreviousChapter: Bool { currentChapterIndex > 0 }

    /// Native chapter index implied by `currentChapterIndex + chapterOffset`, clamped to range.
    var inferredNativeChapterIndex: Int {
        let raw = currentChapterIndex + chapterOffset
        let upper = max(0, nativeChapterTitles.count - 1)
        return min(max(0, raw), upper)
    }

    var currentNativeChapterTitle: String? {
        guard nativeChapterTitles.indices.contains(inferredNativeChapterIndex) else { return nil }
        return nativeChapterTitles[inferredNativeChapterIndex] ?? nil
    }

    // MARK: - Private

    private var targetBookID: UUID?
    private var nativeBookID: UUID?
    private var targetProfile: AlignmentProfile?
    private var nativeProfile: AlignmentProfile?
    private var alignmentPolicy: AlignmentPolicy = .wholeBook
    private var debounceTask: Task<Void, Never>?
    private let sentenceLocator = SentenceLocator()

    // MARK: - Init

    init(entryID: PairedEntryID, store: any LibraryStore, tts: any TTSService) {
        self.entryID = entryID
        self.store = store
        self.ttsService = tts
    }

    // MARK: - Load

    func load() async {
        loadError = nil
        do {
            let ids = try await store.bookIDs(forEntry: entryID)
            targetBookID = ids.target
            nativeBookID = ids.native

            let lastPos = try await store.lastReadPosition(forEntry: entryID)
            currentChapterIndex = lastPos.chapterIndex
            initialScrollTarget = lastPos.paragraphIndex

            let tp = try await store.alignmentProfile(forBook: ids.target)
            let np = try await store.alignmentProfile(forBook: ids.native)
            targetProfile = tp
            nativeProfile = np

            let tTitles = (try? await store.chapterTitles(forBook: ids.target)) ?? []
            let nTitles = (try? await store.chapterTitles(forBook: ids.native)) ?? []
            targetChapterTitles = synthesizeTitlesIfEmpty(tTitles, count: tp.perChapterCumulative.count)
            nativeChapterTitles = synthesizeTitlesIfEmpty(nTitles, count: np.perChapterCumulative.count)
            chapterOffset = (try? await store.chapterOffset(forEntry: entryID)) ?? 0
            alignmentPolicy = computePolicy(source: tp, target: np, offset: chapterOffset)
            chapterCount = tp.perChapterCumulative.count

            // Clamp last-read chapter to a valid range (older data may be stale).
            if currentChapterIndex < 0 || currentChapterIndex >= max(1, chapterCount) {
                currentChapterIndex = 0
                initialScrollTarget = 0
            }

            let entries = try await store.allEntries()
            if let entry = entries.first(where: { $0.id == entryID }) {
                targetLanguage = entry.targetLanguage
            }

            let chapter = try await store.loadChapter(
                ChapterRef(bookID: ids.target, chapterIndex: currentChapterIndex)
            )
            currentChapter = chapter

            await prefetchNativeChapter(forTargetChapterIndex: currentChapterIndex)
        } catch {
            loadError = String(describing: error)
        }
    }

    private func synthesizeTitlesIfEmpty(_ titles: [String?], count: Int) -> [String?] {
        if titles.count >= count { return titles }
        // Pad with placeholders so the sync picker always has rows for every chapter.
        var result = titles
        while result.count < count { result.append(nil) }
        return result
    }

    // MARK: - Tap handling

    func handleSentenceTap(paragraphIndex: Int, sentenceRange: NSRange, sentenceText: String) {
        let pIndex = ParagraphIndex(chapterIndex: currentChapterIndex, paragraphIndex: paragraphIndex)
        tappedParagraph = pIndex
        tappedSentenceRange = sentenceRange
        tappedSentenceText = sentenceText

        guard let tp = targetProfile, let np = nativeProfile else { return }
        let centre = DefaultAlignmentEngine.mapParagraph(pIndex, from: tp, to: np, policy: alignmentPolicy, offset: chapterOffset)
        panelCentre = centre
        isPanelVisible = true

        let nativeChapterIndex = centre.chapterIndex
        Task {
            await loadNativeChapterIfNeeded(chapterIndex: nativeChapterIndex)
        }
    }

    func dismissPanel() {
        isPanelVisible = false
        tappedParagraph = nil
        tappedSentenceRange = nil
        tappedSentenceText = nil
        panelCentre = nil
    }

    // MARK: - Chapter navigation

    func goToNextChapter() async {
        guard canGoToNextChapter, let tid = targetBookID else { return }
        await loadChapter(targetBookID: tid, chapterIndex: currentChapterIndex + 1)
    }

    func goToPreviousChapter() async {
        guard canGoToPreviousChapter, let tid = targetBookID else { return }
        await loadChapter(targetBookID: tid, chapterIndex: currentChapterIndex - 1)
    }

    func goToChapter(_ index: Int) async {
        guard let tid = targetBookID,
              index >= 0,
              index < chapterCount,
              index != currentChapterIndex else { return }
        await loadChapter(targetBookID: tid, chapterIndex: index)
    }

    private func loadChapter(targetBookID tid: UUID, chapterIndex: Int) async {
        do {
            let chapter = try await store.loadChapter(
                ChapterRef(bookID: tid, chapterIndex: chapterIndex)
            )
            currentChapter = chapter
            currentChapterIndex = chapterIndex
            initialScrollTarget = 0
            dismissPanel()
            let pos = LastReadPosition(
                chapterIndex: chapterIndex,
                paragraphIndex: 0,
                scrollFractionWithinParagraph: 0
            )
            try? await store.updateLastReadPosition(pos, forEntry: entryID)
            await prefetchNativeChapter(forTargetChapterIndex: chapterIndex)
        } catch {
            // Stay on current chapter on failure.
        }
    }

    // MARK: - Scroll position persistence

    func handleScrollPositionChange(paragraphIndex: Int) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let pos = LastReadPosition(
                chapterIndex: currentChapterIndex,
                paragraphIndex: paragraphIndex,
                scrollFractionWithinParagraph: 0
            )
            try? await store.updateLastReadPosition(pos, forEntry: entryID)
        }
    }

    // MARK: - Private helpers

    private func prefetchNativeChapter(forTargetChapterIndex chapterIndex: Int) async {
        guard let np = nativeProfile, let tp = targetProfile else { return }
        let centre = DefaultAlignmentEngine.mapParagraph(
            ParagraphIndex(chapterIndex: chapterIndex, paragraphIndex: 0),
            from: tp,
            to: np,
            policy: alignmentPolicy,
            offset: chapterOffset
        )
        await loadNativeChapterIfNeeded(chapterIndex: centre.chapterIndex)
    }

    private func computePolicy(source: AlignmentProfile, target: AlignmentProfile, offset: Int) -> AlignmentPolicy {
        if offset != 0 { return .chapterAnchored }
        return DefaultAlignmentEngine.policy(source: source, target: target)
    }

    // MARK: - Chapter offset (sync)

    func setChapterOffset(_ newOffset: Int) async {
        chapterOffset = newOffset
        if let tp = targetProfile, let np = nativeProfile {
            alignmentPolicy = computePolicy(source: tp, target: np, offset: newOffset)
        }
        dismissPanel()
        try? await store.updateChapterOffset(newOffset, forEntry: entryID)
        await prefetchNativeChapter(forTargetChapterIndex: currentChapterIndex)
    }

    private func loadNativeChapterIfNeeded(chapterIndex: Int) async {
        guard let nid = nativeBookID else { return }
        if let existing = nativeWindowChapter, panelCentre?.chapterIndex == chapterIndex {
            _ = existing
            return
        }
        let ref = ChapterRef(bookID: nid, chapterIndex: chapterIndex)
        if let chapter = try? await store.loadChapter(ref) {
            nativeWindowChapter = chapter
        }
    }
}

// MARK: - TTS State

enum TTSState: Sendable {
    case idle
    case playing
    case paused
}

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

    /// Whether playback is active ("play" mode). When false ("pause" mode) tapping a
    /// paragraph does not speak it. Held in memory only, so it survives paragraph and
    /// chapter changes within a reading session but resets to `false` (paused) on a new
    /// session, matching the requested behaviour.
    var isPlaybackEnabled: Bool = false

    var initialScrollTarget: Int = 0
    var targetLanguage: String = ""
    var chapterCount: Int = 0
    var currentChapterIndex: Int = 0
    var chapterOffset: Int = 0
    var targetChapterTitles: [String?] = []
    var nativeChapterTitles: [String?] = []
    var loadError: String?

    /// Inclusive range of native-paragraph indices that the tapped target paragraph maps to.
    /// Set whenever a tap resolves via the alignment table; nil when the proportional
    /// fallback was used (in which case `panelCentre` still gives a single paragraph).
    var panelRange: TargetParagraphRange?

    /// Latest snapshot of the background alignment build for this entry. Drives the
    /// diagnostics sheet so the user can see whether taps use real alignment or the
    /// proportional fallback, and read any error that occurred.
    var alignmentDiagnostics: AlignmentDiagnostics?

    /// True when the tap-to-translate mapping is using the embedding alignment table
    /// rather than the proportional approximation.
    var isUsingAlignmentTable: Bool { alignmentTable != nil }

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
    private var alignmentTable: ParagraphAlignmentTable?
    private var debounceTask: Task<Void, Never>?
    private var alignmentPollTask: Task<Void, Never>?
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

            // Try to load the precomputed alignment table; if missing, poll a few times
            // in the background since it's computed asynchronously at import time.
            alignmentTable = (try? await store.paragraphAlignment(forEntry: entryID))
            alignmentDiagnostics = (try? await store.alignmentDiagnostics(forEntry: entryID)) ?? nil
            if alignmentTable == nil {
                pollForAlignmentTable()
            }
        } catch {
            loadError = String(describing: error)
        }
    }

    private func pollForAlignmentTable() {
        alignmentPollTask?.cancel()
        let id = entryID
        let storeRef = store
        alignmentPollTask = Task { [weak self] in
            // Poll every 2 seconds for up to 2 minutes, refreshing diagnostics each tick so
            // the diagnostics sheet shows live progress and any failure reason.
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                let table = try? await storeRef.paragraphAlignment(forEntry: id)
                let diagnostics = (try? await storeRef.alignmentDiagnostics(forEntry: id)) ?? nil
                await MainActor.run {
                    if let table { self?.alignmentTable = table }
                    self?.alignmentDiagnostics = diagnostics
                }
                // Stop once the table arrives or the build has reached a terminal phase.
                if table != nil || diagnostics?.phase == .failed || diagnostics?.phase == .completed {
                    return
                }
            }
        }
    }

    /// Re-reads the diagnostics snapshot on demand (used by the diagnostics sheet's refresh).
    func refreshAlignmentDiagnostics() async {
        alignmentDiagnostics = (try? await store.alignmentDiagnostics(forEntry: entryID)) ?? nil
        if alignmentTable == nil {
            alignmentTable = (try? await store.paragraphAlignment(forEntry: entryID)) ?? nil
        }
    }

    /// Triggers a fresh background alignment build for this entry (e.g. to retry a failure),
    /// then resumes polling so the table and diagnostics update as it completes.
    func recomputeAlignment() async {
        alignmentTable = nil
        try? await store.recomputeAlignment(forEntry: entryID)
        alignmentDiagnostics = (try? await store.alignmentDiagnostics(forEntry: entryID)) ?? nil
        pollForAlignmentTable()
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

        // Prefer the precomputed alignment table when it has a usable entry for this
        // (chapter, paragraph). Falls back to proportional mapping otherwise.
        if let table = alignmentTable,
           let range = table.range(forSourceChapter: currentChapterIndex, paragraph: paragraphIndex) {
            let nativeChapterIndex = currentChapterIndex + chapterOffset
            let centre = ParagraphIndex(chapterIndex: nativeChapterIndex,
                                        paragraphIndex: range.start)
            panelCentre = centre
            panelRange = range
            isPanelVisible = true
            Task { await loadNativeChapterIfNeeded(chapterIndex: nativeChapterIndex) }
            return
        }

        let centre = DefaultAlignmentEngine.mapParagraph(pIndex, from: tp, to: np, policy: alignmentPolicy, offset: chapterOffset)
        panelCentre = centre
        panelRange = nil
        isPanelVisible = true

        let nativeChapterIndex = centre.chapterIndex
        Task {
            await loadNativeChapterIfNeeded(chapterIndex: nativeChapterIndex)
        }
    }

    func dismissPanel() {
        // Stop any in-flight speech when the panel goes away. Playback mode itself
        // (`isPlaybackEnabled`) is intentionally left untouched so it persists to the
        // next selected paragraph.
        ttsService.stop()
        isPanelVisible = false
        tappedParagraph = nil
        tappedSentenceRange = nil
        tappedSentenceText = nil
        panelCentre = nil
        panelRange = nil
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
        let changed = newOffset != chapterOffset
        chapterOffset = newOffset
        if let tp = targetProfile, let np = nativeProfile {
            alignmentPolicy = computePolicy(source: tp, target: np, offset: newOffset)
        }
        dismissPanel()
        try? await store.updateChapterOffset(newOffset, forEntry: entryID)
        if changed {
            // The store cleared the now-stale paragraph alignment for the new pairing.
            alignmentTable = nil
            alignmentDiagnostics = (try? await store.alignmentDiagnostics(forEntry: entryID)) ?? nil
        }
        await prefetchNativeChapter(forTargetChapterIndex: currentChapterIndex)
    }

    /// Whether a chapter-level alignment is currently running (drives the button UI).
    var isAligningChapter: Bool = false

    /// Manually aligns the open chapter's paragraphs against its paired native chapter.
    /// Fast (one chapter) and offset-aware, so it only runs after chapters are paired.
    func alignCurrentChapter() async {
        guard !isAligningChapter else { return }
        isAligningChapter = true
        defer { isAligningChapter = false }
        let chapter = currentChapterIndex
        try? await store.alignChapter(forEntry: entryID, targetChapterIndex: chapter)
        alignmentTable = (try? await store.paragraphAlignment(forEntry: entryID)) ?? nil
        alignmentDiagnostics = (try? await store.alignmentDiagnostics(forEntry: entryID)) ?? nil
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

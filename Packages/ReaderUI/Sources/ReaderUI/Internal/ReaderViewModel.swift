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
    /// Language of the native (second) book, used as the target for word translation.
    var nativeLanguage: String = ""
    /// Title of the target book, recorded on saved vocabulary cards for context.
    var bookTitle: String = ""
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

    // MARK: - Word translation balloon

    /// The selected word or phrase to translate, or nil when no balloon is shown.
    var selectedWordText: String?
    /// Paragraph that owns the current word selection (drives which paragraph tints it).
    var selectedWordParagraphIndex: Int?
    /// Character range of the current word selection within its paragraph.
    var selectedWordRange: NSRange?
    /// Selection bounding rect in global coordinates, used to place the balloon.
    var selectedWordAnchor: CGRect?
    /// The selected text that was most recently saved to the deck, so the balloon can
    /// show a filled bookmark for it.
    var lastSavedWordKey: String?
    /// The native sentence (from the aligned parallel book) that contains the selected
    /// word. Computed silently when a word is selected and stored on the saved card so
    /// the review screen can show the real translation. nil until resolved.
    var selectedWordContext: String?

    /// Native sentence(s) the tapped target sentence maps to, computed by the fine
    /// sentence-alignment layer. Empty while the refinement is still running (in which
    /// case the panel falls back to highlighting the whole `panelRange` paragraphs).
    var nativeSentenceHighlights: [SentenceHighlight] = []

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
    private var sentenceRefineTask: Task<Void, Never>?
    private var wordContextTask: Task<Void, Never>?
    /// Per-source-paragraph cache of the sentence-to-native-sentence alignment, so
    /// tapping different sentences in the same paragraph reuses one embedding pass.
    /// Cleared when the chapter or chapter offset changes (which invalidates the basis).
    private var sentenceRefineCache: [Int: [TargetParagraphRange?]] = [:]
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
                nativeLanguage = entry.nativeLanguage
                bookTitle = entry.title
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
        // Clear any prior sentence highlight; the refinement below repopulates it.
        nativeSentenceHighlights = []

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
            startSentenceRefinement(targetParagraphIndex: paragraphIndex,
                                    tappedSentenceRange: sentenceRange,
                                    nativeChapterIndex: nativeChapterIndex,
                                    nativeRange: range)
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
        // No paragraph range from the table here; refine within the single mapped
        // native paragraph so the highlight still narrows to a sentence.
        startSentenceRefinement(targetParagraphIndex: paragraphIndex,
                                tappedSentenceRange: sentenceRange,
                                nativeChapterIndex: nativeChapterIndex,
                                nativeRange: TargetParagraphRange(start: centre.paragraphIndex,
                                                                  end: centre.paragraphIndex))
    }

    // MARK: - Word translation

    /// Records a finalised long-press word/phrase selection so the balloon can show its
    /// offline translation. Independent of the bottom paragraph panel.
    func handleWordSelection(paragraphIndex: Int, range: NSRange, text: String, anchor: CGRect) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selectedWordParagraphIndex = paragraphIndex
        selectedWordRange = range
        selectedWordText = trimmed
        selectedWordAnchor = anchor

        // Resolve the matching sentence from the aligned native book in the background so
        // it can be stored on the card when saved. Not shown in the reader.
        selectedWordContext = nil
        wordContextTask?.cancel()
        wordContextTask = Task { [weak self] in
            await self?.computeWordContext(paragraphIndex: paragraphIndex, wordRange: range)
        }
    }

    func dismissWordBalloon() {
        wordContextTask?.cancel()
        selectedWordText = nil
        selectedWordParagraphIndex = nil
        selectedWordRange = nil
        selectedWordAnchor = nil
        selectedWordContext = nil
    }

    /// Builds a `SavedWordRequest` from the current word selection plus the resolved
    /// `translation`, locating the sentence the word lives in (the recall context) and
    /// re-basing the word's character range into that sentence. Returns nil if the
    /// selection state is incomplete.
    func makeSaveRequest(translation: String) -> SavedWordRequest? {
        guard let surface = selectedWordText,
              let pIndex = selectedWordParagraphIndex,
              let range = selectedWordRange,
              let paragraphs = currentChapter?.paragraphs,
              pIndex < paragraphs.count else { return nil }

        let paragraph = paragraphs[pIndex]
        let (sentence, wordRange) = containingSentence(in: paragraph, wordRange: range)
        return SavedWordRequest(
            surface: surface,
            sentence: sentence,
            wordLocation: wordRange.location,
            wordLength: wordRange.length,
            translation: translation,
            nativeContext: selectedWordContext,
            targetLanguage: targetLanguage,
            nativeLanguage: nativeLanguage,
            bookTitle: bookTitle.isEmpty ? nil : bookTitle,
            chapterIndex: currentChapterIndex
        )
    }

    /// Returns the sentence enclosing `wordRange` within `paragraph`, plus the word's
    /// range expressed in that sentence's coordinates (for cloze blanking later).
    private func containingSentence(in paragraph: String, wordRange: NSRange) -> (sentence: String, wordRange: NSRange) {
        let ns = paragraph as NSString
        let sentences = SentenceLocator.buildSentenceRanges(for: paragraph)
        let enclosing = sentences.first { NSLocationInRange(wordRange.location, $0) } ?? sentences.last
        guard let s = enclosing else {
            return (ns.substring(with: wordRange), NSRange(location: 0, length: wordRange.length))
        }
        let sentenceText = ns.substring(with: s)
        let localLocation = max(0, wordRange.location - s.location)
        let localLength = min(wordRange.length, (sentenceText as NSString).length - localLocation)
        return (sentenceText, NSRange(location: localLocation, length: max(0, localLength)))
    }

    func dismissPanel() {
        // Stop any in-flight speech when the panel goes away. Playback mode itself
        // (`isPlaybackEnabled`) is intentionally left untouched so it persists to the
        // next selected paragraph.
        ttsService.stop()
        sentenceRefineTask?.cancel()
        isPanelVisible = false
        tappedParagraph = nil
        tappedSentenceRange = nil
        tappedSentenceText = nil
        panelCentre = nil
        panelRange = nil
        nativeSentenceHighlights = []
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
            sentenceRefineCache.removeAll()
            dismissPanel()
            dismissWordBalloon()
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
            sentenceRefineCache.removeAll()
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

    // MARK: - Sentence refinement

    /// Refines the coarse paragraph mapping down to the native sentence(s) that match the
    /// tapped target sentence. The panel shows the paragraph-range highlight immediately;
    /// this upgrades it to a sentence highlight once the (cheap, bounded) embedding pass
    /// over just this paragraph's sentences completes.
    private func startSentenceRefinement(targetParagraphIndex: Int,
                                         tappedSentenceRange: NSRange,
                                         nativeChapterIndex: Int,
                                         nativeRange: TargetParagraphRange) {
        sentenceRefineTask?.cancel()
        guard let targetParas = currentChapter?.paragraphs,
              targetParagraphIndex < targetParas.count else { return }
        let targetText = targetParas[targetParagraphIndex]
        let sourceSentenceRanges = SentenceLocator.buildSentenceRanges(for: targetText)
        guard !sourceSentenceRanges.isEmpty else { return }
        let tappedSentenceIndex = sourceSentenceRanges.firstIndex {
            NSLocationInRange(tappedSentenceRange.location, $0)
        } ?? sourceSentenceRanges.firstIndex { $0.location == tappedSentenceRange.location } ?? 0

        sentenceRefineTask = Task { [weak self] in
            await self?.performSentenceRefinement(
                targetParagraphIndex: targetParagraphIndex,
                targetText: targetText,
                sourceSentenceRanges: sourceSentenceRanges,
                tappedSentenceIndex: tappedSentenceIndex,
                nativeChapterIndex: nativeChapterIndex,
                nativeRange: nativeRange
            )
        }
    }

    private func performSentenceRefinement(targetParagraphIndex: Int,
                                           targetText: String,
                                           sourceSentenceRanges: [NSRange],
                                           tappedSentenceIndex: Int,
                                           nativeChapterIndex: Int,
                                           nativeRange: TargetParagraphRange) async {
        await loadNativeChapterIfNeeded(chapterIndex: nativeChapterIndex)
        guard !Task.isCancelled,
              let nativeParas = nativeWindowChapter?.paragraphs,
              panelCentre?.chapterIndex == nativeChapterIndex else { return }

        let start = max(0, nativeRange.start)
        let end = min(nativeParas.count - 1, nativeRange.end)
        guard start <= end else { return }

        // Flatten the native range into a sentence list, keeping each sentence's home
        // paragraph and in-paragraph character range so we can highlight it later.
        var nativeSentenceTexts: [String] = []
        var provenance: [SentenceHighlight] = []
        for p in start...end {
            let paragraphText = nativeParas[p]
            let ns = paragraphText as NSString
            for r in SentenceLocator.buildSentenceRanges(for: paragraphText) {
                nativeSentenceTexts.append(ns.substring(with: r))
                provenance.append(SentenceHighlight(paragraphIndex: p, range: r))
            }
        }
        guard !nativeSentenceTexts.isEmpty else { return }

        let sourceTexts = sourceSentenceRanges.map { (targetText as NSString).substring(with: $0) }

        let alignment: [TargetParagraphRange?]
        if let cached = sentenceRefineCache[targetParagraphIndex] {
            alignment = cached
        } else {
            let computed = try? await SentenceAligner.align(source: sourceTexts, target: nativeSentenceTexts)
            if Task.isCancelled { return }
            if let computed, computed.count == sourceTexts.count {
                alignment = computed
                sentenceRefineCache[targetParagraphIndex] = computed
            } else {
                alignment = []
            }
        }

        let nativeIndices = matchedNativeIndices(
            forTapped: tappedSentenceIndex,
            alignment: alignment,
            sourceCount: sourceTexts.count,
            nativeCount: nativeSentenceTexts.count
        )

        let highlights = nativeIndices.compactMap { idx -> SentenceHighlight? in
            guard idx >= 0, idx < provenance.count else { return nil }
            return provenance[idx]
        }
        guard !highlights.isEmpty, !Task.isCancelled else { return }

        nativeSentenceHighlights = highlights
        if let first = highlights.first {
            panelCentre = ParagraphIndex(chapterIndex: nativeChapterIndex,
                                         paragraphIndex: first.paragraphIndex)
        }
    }

    /// Chooses which native sentence indices correspond to the tapped source sentence,
    /// using the embedding alignment when present and a proportional fallback otherwise.
    /// Shared by the panel highlight path and the word-balloon context path.
    private func matchedNativeIndices(forTapped tappedSentenceIndex: Int,
                                      alignment: [TargetParagraphRange?],
                                      sourceCount: Int,
                                      nativeCount: Int) -> [Int] {
        guard nativeCount > 0 else { return [] }
        if tappedSentenceIndex < alignment.count, let range = alignment[tappedSentenceIndex] {
            return Array(range.start...min(range.end, nativeCount - 1))
        }
        let denom = max(1, sourceCount - 1)
        let fraction = Double(tappedSentenceIndex) / Double(denom)
        let idx = Int((fraction * Double(max(0, nativeCount - 1))).rounded())
        return [min(max(0, idx), nativeCount - 1)]
    }

    // MARK: - Word context (aligned native sentence)

    /// Resolves the native (chapter, paragraph-range) a target paragraph maps to, using
    /// the same precedence as `handleSentenceTap`: the alignment table when it has an
    /// entry, otherwise the proportional engine.
    private func resolveNativeMapping(targetParagraphIndex: Int) -> (chapterIndex: Int, range: TargetParagraphRange)? {
        guard let tp = targetProfile, let np = nativeProfile else { return nil }
        if let table = alignmentTable,
           let range = table.range(forSourceChapter: currentChapterIndex, paragraph: targetParagraphIndex) {
            return (currentChapterIndex + chapterOffset, range)
        }
        let centre = DefaultAlignmentEngine.mapParagraph(
            ParagraphIndex(chapterIndex: currentChapterIndex, paragraphIndex: targetParagraphIndex),
            from: tp, to: np, policy: alignmentPolicy, offset: chapterOffset
        )
        return (centre.chapterIndex, TargetParagraphRange(start: centre.paragraphIndex, end: centre.paragraphIndex))
    }

    /// Computes the native sentence(s) from the parallel book that align with the sentence
    /// the long-pressed word lives in, and publishes them to `selectedWordContext`. Runs
    /// off the panel state so it never opens or disturbs the bottom panel.
    private func computeWordContext(paragraphIndex: Int, wordRange: NSRange) async {
        guard let targetParas = currentChapter?.paragraphs,
              paragraphIndex < targetParas.count else { return }
        let targetText = targetParas[paragraphIndex]
        let sourceRanges = SentenceLocator.buildSentenceRanges(for: targetText)
        guard !sourceRanges.isEmpty else { return }
        let tappedIndex = sourceRanges.firstIndex { NSLocationInRange(wordRange.location, $0) } ?? 0

        guard let mapping = resolveNativeMapping(targetParagraphIndex: paragraphIndex),
              let nid = nativeBookID else { return }

        let nativeChapter = try? await store.loadChapter(
            ChapterRef(bookID: nid, chapterIndex: mapping.chapterIndex)
        )
        guard !Task.isCancelled, let nativeParas = nativeChapter?.paragraphs else { return }
        let start = max(0, mapping.range.start)
        let end = min(nativeParas.count - 1, mapping.range.end)
        guard start <= end else { return }

        var nativeTexts: [String] = []
        for p in start...end {
            let ns = nativeParas[p] as NSString
            for r in SentenceLocator.buildSentenceRanges(for: nativeParas[p]) {
                nativeTexts.append(ns.substring(with: r))
            }
        }
        guard !nativeTexts.isEmpty else { return }

        let sourceTexts = sourceRanges.map { (targetText as NSString).substring(with: $0) }

        let alignment: [TargetParagraphRange?]
        if let cached = sentenceRefineCache[paragraphIndex] {
            alignment = cached
        } else {
            let computed = try? await SentenceAligner.align(source: sourceTexts, target: nativeTexts)
            if Task.isCancelled { return }
            if let computed, computed.count == sourceTexts.count {
                alignment = computed
                sentenceRefineCache[paragraphIndex] = computed
            } else {
                alignment = []
            }
        }

        let indices = matchedNativeIndices(
            forTapped: tappedIndex,
            alignment: alignment,
            sourceCount: sourceTexts.count,
            nativeCount: nativeTexts.count
        )
        let matched = indices.compactMap { $0 >= 0 && $0 < nativeTexts.count ? nativeTexts[$0] : nil }
        guard !matched.isEmpty, !Task.isCancelled else { return }

        // Only publish if the user hasn't moved on to another selection.
        if selectedWordParagraphIndex == paragraphIndex {
            selectedWordContext = matched.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// A sentence to highlight inside the native chapter: which paragraph, and the character
/// range within that paragraph's text.
struct SentenceHighlight: Equatable, Sendable {
    let paragraphIndex: Int
    let range: NSRange
}

// MARK: - TTS State

enum TTSState: Sendable {
    case idle
    case playing
    case paused
}

import SwiftUI
import LibraryStore
import TTSService

/// A request to save a long-pressed word/phrase to the vocabulary deck. Emitted by the
/// reader; the host app performs lemmatization and persistence (keeps ReaderUI free of a
/// VocabKit dependency). All character indices are NSString-based.
public struct SavedWordRequest: Sendable, Equatable {
    /// The inflected form as it appeared in the text.
    public let surface: String
    /// The sentence the word was tapped in (the recall context / cloze source).
    public let sentence: String
    /// Location of `surface` within `sentence`.
    public let wordLocation: Int
    /// Length of `surface` within `sentence`.
    public let wordLength: Int
    /// Offline translation shown in the balloon at save time.
    public let translation: String
    /// The sentence from the aligned parallel (native) book that contains this word, taken
    /// directly from the translation. nil if alignment wasn't resolved in time.
    public let nativeContext: String?
    public let targetLanguage: String
    public let nativeLanguage: String
    public let bookTitle: String?
    public let chapterIndex: Int

    public init(
        surface: String,
        sentence: String,
        wordLocation: Int,
        wordLength: Int,
        translation: String,
        nativeContext: String?,
        targetLanguage: String,
        nativeLanguage: String,
        bookTitle: String?,
        chapterIndex: Int
    ) {
        self.surface = surface
        self.sentence = sentence
        self.wordLocation = wordLocation
        self.wordLength = wordLength
        self.translation = translation
        self.nativeContext = nativeContext
        self.targetLanguage = targetLanguage
        self.nativeLanguage = nativeLanguage
        self.bookTitle = bookTitle
        self.chapterIndex = chapterIndex
    }
}

/// The primary reading view. Shows the target-language text in a scrollable list of paragraphs.
/// Tapping a sentence highlights it and presents a translation panel with mapped native paragraphs.
public struct ReaderView: View {
    private let entryID: PairedEntryID
    private let onSaveWord: (SavedWordRequest) -> Void
    @State private var viewModel: ReaderViewModel
    @State private var settings: ReaderSettings = .default
    @AppStorage("readerUI.voicePromptShown") private var voicePromptShown: Bool = false
    @State private var showVoiceAlert: Bool = false
    @State private var presentingSyncSheet: Bool = false
    @State private var presentingDiagnostics: Bool = false
    /// Reader content frame in global coordinates, used to place the word-translation balloon.
    @State private var readerFrame: CGRect = .zero

    /// - Parameter onSaveWord: Called when the user taps Save in the translation balloon.
    ///   The host app lemmatizes and persists to the vocabulary deck. Defaults to a no-op
    ///   so existing call sites (and tests) compile unchanged.
    public init(
        entryID: PairedEntryID,
        store: any LibraryStore,
        tts: any TTSService,
        onSaveWord: @escaping (SavedWordRequest) -> Void = { _ in }
    ) {
        self.entryID = entryID
        self.onSaveWord = onSaveWord
        self._viewModel = State(
            initialValue: ReaderViewModel(entryID: entryID, store: store, tts: tts)
        )
    }

    public var body: some View {
        Group {
            if let chapter = viewModel.currentChapter {
                ChapterScrollView(
                    chapterID: viewModel.currentChapterIndex,
                    paragraphs: chapter.paragraphs,
                    tappedParagraphIndex: viewModel.tappedParagraph?.paragraphIndex,
                    tappedSentenceRange: viewModel.tappedSentenceRange,
                    wordSelectionParagraphIndex: viewModel.selectedWordParagraphIndex,
                    wordSelectionRange: viewModel.selectedWordRange,
                    fontPointSize: settings.fontPointSize,
                    scrollTarget: viewModel.initialScrollTarget,
                    onSentenceTap: { paragraphIndex, range, text in
                        viewModel.handleSentenceTap(
                            paragraphIndex: paragraphIndex,
                            sentenceRange: range,
                            sentenceText: text
                        )
                        // Only speak when in "play" mode; in "pause" mode selecting a
                        // paragraph just opens the panel silently.
                        if viewModel.isPlaybackEnabled {
                            triggerTTSIfNeeded(text: text)
                        }
                    },
                    onWordSelection: { paragraphIndex, range, text, rect in
                        viewModel.handleWordSelection(
                            paragraphIndex: paragraphIndex,
                            range: range,
                            text: text,
                            anchor: rect
                        )
                    },
                    onScrollPositionChange: { paragraphIndex in
                        viewModel.handleScrollPositionChange(paragraphIndex: paragraphIndex)
                    },
                    panelVisible: viewModel.isPanelVisible
                )
            } else if let error = viewModel.loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("Couldn't load this book")
                        .font(.headline)
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button("Try Again") {
                        Task { await viewModel.load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle(chapterTitle)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                FontSizeControl(fontPointSize: $settings.fontPointSize)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    presentingDiagnostics = true
                } label: {
                    Image(systemName: alignmentStatusIcon)
                        .foregroundStyle(alignmentStatusTint)
                }
                .accessibilityLabel("Alignment status")
            }
            ToolbarItemGroup(placement: bottomBarPlacement) {
                Button {
                    Task { await viewModel.goToPreviousChapter() }
                } label: {
                    Label("Previous Chapter", systemImage: "chevron.left")
                }
                .disabled(!viewModel.canGoToPreviousChapter)

                Spacer()

                if viewModel.chapterCount > 0 {
                    Button {
                        presentingSyncSheet = true
                    } label: {
                        VStack(spacing: 1) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.left.arrow.right")
                                    .imageScale(.small)
                                Text("Ch \(viewModel.currentChapterIndex + 1)/\(viewModel.chapterCount)")
                                    .font(.footnote.weight(.medium))
                            }
                            if viewModel.chapterOffset != 0 {
                                Text("native \(viewModel.inferredNativeChapterIndex + 1) (offset \(viewModel.chapterOffset >= 0 ? "+" : "")\(viewModel.chapterOffset))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("tap to sync")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .accessibilityLabel("Sync chapters")
                }

                Spacer()

                Button {
                    Task { await viewModel.goToNextChapter() }
                } label: {
                    Label("Next Chapter", systemImage: "chevron.right")
                }
                .disabled(!viewModel.canGoToNextChapter)
            }
        }
        .sheet(isPresented: $presentingSyncSheet) {
            SyncChaptersSheet(
                targetTitles: viewModel.targetChapterTitles,
                nativeTitles: viewModel.nativeChapterTitles,
                currentTargetIndex: viewModel.currentChapterIndex,
                currentOffset: viewModel.chapterOffset,
                onPickNative: { nativeIndex in
                    let newOffset = nativeIndex - viewModel.currentChapterIndex
                    presentingSyncSheet = false
                    Task { await viewModel.setChapterOffset(newOffset) }
                },
                onPickTarget: { targetIndex in
                    presentingSyncSheet = false
                    Task { await viewModel.goToChapter(targetIndex) }
                },
                onClear: {
                    Task { await viewModel.setChapterOffset(0) }
                },
                onCancel: {
                    presentingSyncSheet = false
                }
            )
        }
        .sheet(isPresented: $presentingDiagnostics) {
            AlignmentDiagnosticsView(
                diagnostics: viewModel.alignmentDiagnostics,
                isUsingTable: viewModel.isUsingAlignmentTable,
                currentChapterNumber: viewModel.currentChapterIndex + 1,
                onAlignChapter: { await viewModel.alignCurrentChapter() },
                onRefresh: { await viewModel.refreshAlignmentDiagnostics() },
                onRecompute: { await viewModel.recomputeAlignment() },
                onDismiss: { presentingDiagnostics = false }
            )
        }
        .task {
            await viewModel.load()
        }
        .overlay(alignment: .bottom) {
            if viewModel.isPanelVisible, let centre = viewModel.panelCentre {
                TranslationPanel(
                    nativeChapter: viewModel.nativeWindowChapter,
                    centreParagraphIndex: centre.paragraphIndex,
                    highlightRange: viewModel.panelRange,
                    sentenceHighlights: viewModel.nativeSentenceHighlights,
                    settings: $settings,
                    isPlaying: viewModel.isPlaybackEnabled,
                    onPlayPause: {
                        if viewModel.isPlaybackEnabled {
                            // Pause: stop playback and leave the panel open.
                            viewModel.isPlaybackEnabled = false
                            viewModel.ttsService.stop()
                        } else {
                            // Play: start reading the currently selected paragraph.
                            viewModel.isPlaybackEnabled = true
                            if let text = viewModel.tappedSentenceText {
                                triggerTTSIfNeeded(text: text)
                            }
                        }
                    },
                    onSync: {
                        viewModel.dismissPanel()
                        presentingSyncSheet = true
                    },
                    onDismiss: { viewModel.dismissPanel() }
                )
                .transition(.move(edge: .bottom))
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { readerFrame = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, frame in
                        readerFrame = frame
                    }
            }
        )
        .overlay {
            if let text = viewModel.selectedWordText,
               let anchor = viewModel.selectedWordAnchor {
                WordTranslationBalloon(
                    text: text,
                    sourceLanguage: viewModel.targetLanguage,
                    targetLanguage: viewModel.nativeLanguage,
                    anchorInGlobal: anchor,
                    containerFrame: readerFrame,
                    isSaved: viewModel.lastSavedWordKey == text,
                    onSave: { translation in
                        if let request = viewModel.makeSaveRequest(translation: translation) {
                            onSaveWord(request)
                            viewModel.lastSavedWordKey = text
                        }
                    },
                    onClose: { viewModel.dismissWordBalloon() }
                )
                .id(text)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.isPanelVisible)
        .alert("No Enhanced Voice Installed", isPresented: $showVoiceAlert) {
            Button("Open Settings") {
                if let url = URL(string: "App-Prefs:") {
                    #if canImport(UIKit)
                    UIApplication.shared.open(url)
                    #endif
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("For the best experience, install an enhanced voice for your target language in Settings > Accessibility > Spoken Content > Voices.")
        }
    }

    private var bottomBarPlacement: ToolbarItemPlacement {
        #if os(iOS)
        return .bottomBar
        #else
        return .automatic
        #endif
    }

    /// SF Symbol reflecting the alignment build state, shown in the toolbar.
    private var alignmentStatusIcon: String {
        switch viewModel.alignmentDiagnostics?.phase {
        case .completed: return viewModel.isUsingAlignmentTable ? "wand.and.stars" : "wand.and.stars.inverse"
        case .failed: return "exclamationmark.triangle.fill"
        case .running, .pending: return "hourglass"
        case .none: return "wand.and.stars.inverse"
        }
    }

    private var alignmentStatusTint: Color {
        switch viewModel.alignmentDiagnostics?.phase {
        case .completed: return viewModel.isUsingAlignmentTable ? .green : .orange
        case .failed: return .red
        case .running, .pending: return .blue
        case .none: return .secondary
        }
    }

    private var chapterTitle: String {
        if let title = viewModel.currentChapter?.title, !title.isEmpty {
            return title
        }
        return ""
    }

    private func triggerTTSIfNeeded(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let targetLanguage = viewModel.targetLanguage
        let tts = viewModel.ttsService
        let rate = settings.ttsRate

        if !tts.hasHighQualityVoice(forLanguage: targetLanguage) && !voicePromptShown {
            voicePromptShown = true
            showVoiceAlert = true
        }

        if let voice = tts.bestVoice(forLanguage: targetLanguage) {
            Task {
                await tts.speak(text, voice: voice, rate: rate)
            }
        }
    }
}

// MARK: - Font size toolbar control

private struct FontSizeControl: View {
    @Binding var fontPointSize: Double

    var body: some View {
        Stepper(
            value: $fontPointSize,
            in: 14...28,
            step: 1
        ) {
            Text("Aa")
                .font(.system(size: fontPointSize))
        }
    }
}

import SwiftUI

/// Scrollable list of paragraphs for a single chapter.
/// Sentences are tap-detectable via `SentenceTapOverlay` per paragraph.
struct ChapterScrollView: View {

    /// Identity of the paragraph array (the chapter index). Used so the paragraph list can
    /// skip recomputation while only scroll geometry changes - see `ParagraphListView`.
    let chapterID: Int
    let paragraphs: [String]
    let tappedParagraphIndex: Int?
    let tappedSentenceRange: NSRange?
    /// Paragraph that currently owns a finalised word selection, and its range.
    let wordSelectionParagraphIndex: Int?
    let wordSelectionRange: NSRange?
    let fontPointSize: Double
    let scrollTarget: Int
    let onSentenceTap: (Int, NSRange, String) -> Void
    /// Reports a finalised word selection: paragraph index, character range, selected text,
    /// and the selection's bounding rect in global coordinates.
    let onWordSelection: (Int, NSRange, String, CGRect) -> Void
    let onScrollPositionChange: (Int) -> Void
    var panelVisible: Bool = false

    @State private var availableHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                // The paragraph list is an `Equatable` child so that the frequent
                // `contentHeight` / `availableHeight` @State writes below (which fire as the
                // lazy stack materialises rows during scroll) re-evaluate only this thin
                // wrapper, not the 450-row ForEach. Re-diffing every row each scroll frame is
                // what froze the main thread on device.
                ParagraphListView(
                    chapterID: chapterID,
                    paragraphs: paragraphs,
                    tappedParagraphIndex: tappedParagraphIndex,
                    tappedSentenceRange: tappedSentenceRange,
                    wordSelectionParagraphIndex: wordSelectionParagraphIndex,
                    wordSelectionRange: wordSelectionRange,
                    fontPointSize: fontPointSize,
                    onSentenceTap: onSentenceTap,
                    onWordSelection: onWordSelection,
                    onScrollPositionChange: onScrollPositionChange
                )
                .equatable()
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                // Reserve room so the bottom translation panel never covers the
                // final paragraphs of the chapter.
                .padding(.bottom, panelVisible ? translationPanelInset : 0)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { contentHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, newHeight in
                                contentHeight = newHeight
                            }
                    }
                )
            }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { availableHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, newHeight in
                            availableHeight = newHeight
                        }
                }
            )
            .animation(.easeInOut(duration: 0.25), value: panelVisible)
            .task(id: scrollTarget) {
                if scrollTarget > 0 {
                    proxy.scrollTo(scrollTarget, anchor: .top)
                }
            }
            // Re-tapping while the panel is already open scrolls immediately: the
            // bottom inset is already in the layout, so the tapped paragraph has
            // room to move above the panel.
            .onChange(of: tappedParagraphIndex) { _, newIndex in
                guard let target = newIndex else { return }
                scrollTappedAbovePanel(target, using: proxy)
            }
            // On the first tap the panel's inset enters the layout as a single large
            // jump in content height. That height change is the deterministic signal
            // that the final paragraphs now have room to move up, so the scroll runs
            // then (no timers). Small lazy-loading drift is ignored via the threshold.
            .onChange(of: contentHeight) { oldHeight, newHeight in
                guard panelVisible,
                      newHeight - oldHeight > 100,
                      let target = tappedParagraphIndex else { return }
                scrollTappedAbovePanel(target, using: proxy)
            }
        }
    }

    private func scrollTappedAbovePanel(_ target: Int, using proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(target, anchor: tappedParagraphAnchor)
        }
    }

    /// Mirrors the height the `TranslationPanel` occupies at the bottom of the
    /// screen (`min(height * 0.55, 460)`), plus a buffer so the tapped paragraph
    /// clears the panel comfortably.
    private var translationPanelInset: CGFloat {
        min(availableHeight * 0.55, 460) + 48
    }

    /// Anchor that places a tapped paragraph just inside the visible band above
    /// the panel (the panel starts roughly 55% down the screen), leaving a bit of
    /// preceding context on screen.
    private var tappedParagraphAnchor: UnitPoint {
        guard availableHeight > 0 else { return .top }
        let visibleFraction = (availableHeight - translationPanelInset) / availableHeight
        return UnitPoint(x: 0, y: max(0.1, min(0.3, visibleFraction - 0.12)))
    }
}

// MARK: - ParagraphListView

/// The lazy list of paragraph rows. Conforms to `Equatable` so SwiftUI can skip recomputing
/// the whole `ForEach` when only scroll geometry changed in the parent. Equality intentionally
/// ignores the callback closures (they are recreated every parent render but always target the
/// same view model) and compares the paragraph array by its `chapterID` identity token rather
/// than element-by-element.
private struct ParagraphListView: View, Equatable {
    let chapterID: Int
    let paragraphs: [String]
    let tappedParagraphIndex: Int?
    let tappedSentenceRange: NSRange?
    let wordSelectionParagraphIndex: Int?
    let wordSelectionRange: NSRange?
    let fontPointSize: Double
    let onSentenceTap: (Int, NSRange, String) -> Void
    let onWordSelection: (Int, NSRange, String, CGRect) -> Void
    let onScrollPositionChange: (Int) -> Void

    static func == (lhs: ParagraphListView, rhs: ParagraphListView) -> Bool {
        lhs.chapterID == rhs.chapterID
            && lhs.fontPointSize == rhs.fontPointSize
            && lhs.tappedParagraphIndex == rhs.tappedParagraphIndex
            && lhs.wordSelectionParagraphIndex == rhs.wordSelectionParagraphIndex
            && rangesEqual(lhs.tappedSentenceRange, rhs.tappedSentenceRange)
            && rangesEqual(lhs.wordSelectionRange, rhs.wordSelectionRange)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            // Index-based identity avoids building an `Array(paragraphs.enumerated())` of
            // (Int, String) tuples (and the string hashing/copying that came with it) on
            // every diff pass.
            ForEach(paragraphs.indices, id: \.self) { index in
                ParagraphView(
                    index: index,
                    text: paragraphs[index],
                    isTapped: tappedParagraphIndex == index,
                    tappedSentenceRange: tappedParagraphIndex == index ? tappedSentenceRange : nil,
                    wordHighlightRange: wordSelectionParagraphIndex == index ? wordSelectionRange : nil,
                    fontPointSize: fontPointSize,
                    onSentenceTap: { range, sentenceText in
                        onSentenceTap(index, range, sentenceText)
                    },
                    onWordSelection: { range, selectedText, rect in
                        onWordSelection(index, range, selectedText, rect)
                    }
                )
                .id(index)
                .onAppear {
                    onScrollPositionChange(index)
                }
            }
        }
    }
}

private func rangesEqual(_ a: NSRange?, _ b: NSRange?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (l?, r?): return NSEqualRanges(l, r)
    default: return false
    }
}

// MARK: - ParagraphView

private struct ParagraphView: View {
    let index: Int
    let text: String
    let isTapped: Bool
    let tappedSentenceRange: NSRange?
    let wordHighlightRange: NSRange?
    let fontPointSize: Double
    let onSentenceTap: (NSRange, String) -> Void
    let onWordSelection: (NSRange, String, CGRect) -> Void

    var body: some View {
        SentenceTapOverlay(
            text: text,
            paragraphIndex: index,
            tappedSentenceRange: tappedSentenceRange,
            wordHighlightRange: wordHighlightRange,
            fontPointSize: fontPointSize,
            onSentenceTap: onSentenceTap,
            onWordSelection: onWordSelection
        )
    }
}

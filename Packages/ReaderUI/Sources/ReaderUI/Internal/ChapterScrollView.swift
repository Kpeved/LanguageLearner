import SwiftUI

/// Scrollable list of paragraphs for a single chapter.
/// Sentences are tap-detectable via `SentenceTapOverlay` per paragraph.
struct ChapterScrollView: View {

    let paragraphs: [String]
    let tappedParagraphIndex: Int?
    let tappedSentenceRange: NSRange?
    let fontPointSize: Double
    let scrollTarget: Int
    let onSentenceTap: (Int, NSRange, String) -> Void
    let onScrollPositionChange: (Int) -> Void
    var panelVisible: Bool = false

    @State private var visibleParagraph: Int = 0
    @State private var availableHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, text in
                        ParagraphView(
                            index: index,
                            text: text,
                            isTapped: tappedParagraphIndex == index,
                            tappedSentenceRange: tappedParagraphIndex == index ? tappedSentenceRange : nil,
                            fontPointSize: fontPointSize,
                            onSentenceTap: { range, sentenceText in
                                onSentenceTap(index, range, sentenceText)
                            }
                        )
                        .id(index)
                        .onAppear {
                            visibleParagraph = index
                            onScrollPositionChange(index)
                        }
                    }
                }
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

// MARK: - ParagraphView

private struct ParagraphView: View {
    let index: Int
    let text: String
    let isTapped: Bool
    let tappedSentenceRange: NSRange?
    let fontPointSize: Double
    let onSentenceTap: (NSRange, String) -> Void

    var body: some View {
        SentenceTapOverlay(
            text: text,
            paragraphIndex: index,
            tappedSentenceRange: tappedSentenceRange,
            fontPointSize: fontPointSize,
            onSentenceTap: onSentenceTap
        )
    }
}

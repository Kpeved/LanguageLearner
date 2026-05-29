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

    @State private var visibleParagraph: Int = 0

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
            }
            .task(id: scrollTarget) {
                if scrollTarget > 0 {
                    proxy.scrollTo(scrollTarget, anchor: .top)
                }
            }
        }
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

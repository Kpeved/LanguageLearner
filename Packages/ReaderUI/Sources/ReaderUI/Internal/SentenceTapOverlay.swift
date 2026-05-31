import SwiftUI

/// Renders a single paragraph with tap-to-highlight at sentence granularity, plus a
/// long-press word selector.
///
/// On iOS the paragraph is drawn by a self-sizing `UITextView` so a tap can be
/// hit-tested to the exact character and mapped to the sentence that contains it
/// (`SentenceLocator`). Only that sentence highlights and is emitted as the TTS
/// utterance. A long-press selects the word under the finger; dragging extends the
/// selection word-by-word and, on release, reports the span for offline translation.
/// This is the "real UITextView/TextKit path" the project requires before doing any
/// sub-paragraph hit-testing - it replaces the old, unreliable pixel math.
///
/// On macOS (no UIKit) it falls back to a plain `Text` that emits the whole paragraph.
struct SentenceTapOverlay: View {
    let text: String
    let paragraphIndex: Int
    let tappedSentenceRange: NSRange?
    /// Finalised multi-word selection for this paragraph (nil when the selection lives in
    /// a different paragraph or no word is selected). Drawn with the accent selection tint.
    let wordHighlightRange: NSRange?
    let fontPointSize: Double
    let onSentenceTap: (NSRange, String) -> Void
    /// Reports a finalised word selection: its character range, the selected text, and the
    /// selection's bounding rect in global (window) coordinates for balloon placement.
    let onWordSelection: (NSRange, String, CGRect) -> Void

    var body: some View {
        #if canImport(UIKit)
        SelectableParagraphTextView(
            text: text,
            highlightRange: tappedSentenceRange,
            wordHighlightRange: wordHighlightRange,
            fontPointSize: fontPointSize,
            onSentenceTap: onSentenceTap,
            onWordSelection: onWordSelection
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        #else
        Text(text)
            .font(.system(size: fontPointSize))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(tappedSentenceRange != nil ? Color.yellow.opacity(0.35) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                let fullRange = NSRange(location: 0, length: (text as NSString).length)
                onSentenceTap(fullRange, text)
            }
        #endif
    }
}

#if canImport(UIKit)
import UIKit

/// A non-scrolling, non-editable `UITextView` that wraps to the proposed width, draws a
/// background highlight on `highlightRange`/`wordHighlightRange`, reports the tapped
/// sentence range, and reports long-press word selections.
struct SelectableParagraphTextView: UIViewRepresentable {
    let text: String
    let highlightRange: NSRange?
    let wordHighlightRange: NSRange?
    let fontPointSize: Double
    let onSentenceTap: (NSRange, String) -> Void
    let onWordSelection: (NSRange, String, CGRect) -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isScrollEnabled = false
        textView.isEditable = false
        // We do our own tap/selection handling; system text selection would swallow taps.
        textView.isSelectable = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        // Wrap to the width SwiftUI proposes instead of insisting on the full text width.
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        textView.addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: context.coordinator,
                                                     action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        // Without a movement allowance the recognizer cancels as soon as the drag begins,
        // which is exactly the multi-word drag we want to track.
        longPress.allowableMovement = .greatestFiniteMagnitude
        textView.addGestureRecognizer(longPress)

        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = text
        coordinator.fontPointSize = fontPointSize
        coordinator.sentenceHighlight = highlightRange
        coordinator.onSentenceTap = onSentenceTap
        coordinator.onWordSelection = onWordSelection
        // While a drag is in flight the coordinator owns the live selection; otherwise the
        // SwiftUI-provided range is the source of truth (set on finalise, cleared on dismiss).
        if !coordinator.isDragging {
            coordinator.wordSelection = wordHighlightRange
        }
        coordinator.render(into: uiView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0, width.isFinite else { return nil }
        // Height only depends on (text, width, font). Cache it so a SwiftUI layout pass
        // that re-proposes many paragraphs during scroll does not re-shape every one with
        // CoreText on the main thread, which is what froze the reader.
        let height = ParagraphSizer.shared.height(text: text, width: width, fontPointSize: fontPointSize)
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text,
                    fontPointSize: fontPointSize,
                    onSentenceTap: onSentenceTap,
                    onWordSelection: onWordSelection)
    }

    final class Coordinator: NSObject {
        var text: String
        var fontPointSize: Double
        var sentenceHighlight: NSRange?
        var wordSelection: NSRange?
        var onSentenceTap: (NSRange, String) -> Void
        var onWordSelection: (NSRange, String, CGRect) -> Void

        /// True between a long-press `.began` and its terminal state, while we drive the
        /// selection highlight directly on the text view.
        private(set) var isDragging = false
        private var anchorWord: NSRange?

        /// Snapshot of the inputs the text view was last rendered with, so a redundant
        /// `updateUIView` (common during scroll, when the parent re-evaluates) does not reset
        /// `attributedText` and invalidate the text layout for nothing.
        private var renderedText: String?
        private var renderedFont: Double = 0
        private var renderedSentence: NSRange?
        private var renderedWord: NSRange?
        /// Scroll view disabled for the duration of a drag so selection doesn't fight scroll.
        private weak var lockedScrollView: UIScrollView?

        init(text: String,
             fontPointSize: Double,
             onSentenceTap: @escaping (NSRange, String) -> Void,
             onWordSelection: @escaping (NSRange, String, CGRect) -> Void) {
            self.text = text
            self.fontPointSize = fontPointSize
            self.onSentenceTap = onSentenceTap
            self.onWordSelection = onWordSelection
        }

        // MARK: - Rendering

        func render(into textView: UITextView) {
            // Skip if nothing that affects the drawn text changed since the last render.
            if textView.attributedText.length > 0,
               renderedText == text,
               renderedFont == fontPointSize,
               rangesEqual(renderedSentence, sentenceHighlight),
               rangesEqual(renderedWord, wordSelection) {
                return
            }
            renderedText = text
            renderedFont = fontPointSize
            renderedSentence = sentenceHighlight
            renderedWord = wordSelection

            let nsText = text as NSString
            let attributed = NSMutableAttributedString(
                string: text,
                attributes: [
                    .font: UIFont.systemFont(ofSize: fontPointSize),
                    .foregroundColor: UIColor.label
                ]
            )
            if let range = sentenceHighlight, range.location != NSNotFound,
               NSMaxRange(range) <= nsText.length {
                attributed.addAttribute(.backgroundColor,
                                        value: UIColor.systemYellow.withAlphaComponent(0.35),
                                        range: range)
            }
            if let range = wordSelection, range.location != NSNotFound, range.length > 0,
               NSMaxRange(range) <= nsText.length {
                attributed.addAttribute(.backgroundColor,
                                        value: UIColor.systemBlue.withAlphaComponent(0.30),
                                        range: range)
            }
            textView.attributedText = attributed
        }

        // MARK: - Tap (sentence)

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView = gesture.view as? UITextView else { return }
            let nsText = text as NSString
            guard nsText.length > 0 else { return }

            let index = characterIndex(at: gesture.location(in: textView),
                                       in: textView, length: nsText.length)

            let ranges = SentenceLocator.buildSentenceRanges(for: text)
            guard !ranges.isEmpty else {
                onSentenceTap(NSRange(location: 0, length: nsText.length), text)
                return
            }
            let hit = ranges.first { NSLocationInRange(index, $0) } ?? ranges.last
            guard let sentenceRange = hit else { return }
            onSentenceTap(sentenceRange, nsText.substring(with: sentenceRange))
        }

        // MARK: - Long press (word selection)

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let textView = gesture.view as? UITextView else { return }
            let nsText = text as NSString
            guard nsText.length > 0 else { return }
            let index = characterIndex(at: gesture.location(in: textView),
                                       in: textView, length: nsText.length)

            switch gesture.state {
            case .began:
                isDragging = true
                lockScroll(from: textView)
                anchorWord = WordTokenizer.wordRange(atOffset: index, in: text)
                wordSelection = anchorWord
                render(into: textView)

            case .changed:
                guard let anchor = anchorWord else { return }
                if let current = WordTokenizer.wordRange(atOffset: index, in: text) {
                    wordSelection = WordTokenizer.unite(anchor, current)
                    render(into: textView)
                }

            case .ended:
                isDragging = false
                unlockScroll()
                guard let range = wordSelection, range.length > 0,
                      NSMaxRange(range) <= nsText.length else {
                    anchorWord = nil
                    return
                }
                let selected = nsText.substring(with: range)
                let rect = boundingRect(for: range, in: textView)
                let global = textView.convert(rect, to: nil)
                anchorWord = nil
                onWordSelection(range, selected, global)

            case .cancelled, .failed:
                isDragging = false
                unlockScroll()
                anchorWord = nil
                wordSelection = nil
                render(into: textView)

            default:
                break
            }
        }

        // MARK: - Geometry helpers

        private func characterIndex(at point: CGPoint, in textView: UITextView, length: Int) -> Int {
            let adjusted = CGPoint(x: point.x - textView.textContainerInset.left,
                                   y: point.y - textView.textContainerInset.top)
            var fraction: CGFloat = 0
            // Accessing `layoutManager` opts the text view into TextKit 1, which gives a
            // reliable character hit-test. This is the supported path for index lookup.
            var index = textView.layoutManager.characterIndex(
                for: adjusted,
                in: textView.textContainer,
                fractionOfDistanceBetweenInsertionPoints: &fraction
            )
            if index >= length { index = length - 1 }
            return max(0, index)
        }

        private func boundingRect(for range: NSRange, in textView: UITextView) -> CGRect {
            let layoutManager = textView.layoutManager
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range,
                                                      actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange,
                                                  in: textView.textContainer)
            rect.origin.x += textView.textContainerInset.left
            rect.origin.y += textView.textContainerInset.top
            return rect
        }

        private func lockScroll(from view: UIView) {
            var ancestor = view.superview
            while let current = ancestor {
                if let scrollView = current as? UIScrollView {
                    scrollView.isScrollEnabled = false
                    lockedScrollView = scrollView
                    return
                }
                ancestor = current.superview
            }
        }

        private func unlockScroll() {
            lockedScrollView?.isScrollEnabled = true
            lockedScrollView = nil
        }

        private func rangesEqual(_ a: NSRange?, _ b: NSRange?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (l?, r?): return NSEqualRanges(l, r)
            default: return false
            }
        }
    }
}

/// Caches paragraph heights keyed by (text, width, font) and measures cache misses with a
/// single reusable, off-screen `UITextView` configured exactly like the on-screen ones.
/// Measurement is the expensive part (CoreText line breaking + glyph shaping); doing it once
/// per paragraph instead of on every layout pass is what keeps scrolling smooth.
@MainActor
final class ParagraphSizer {
    static let shared = ParagraphSizer()

    private let measuringView: UITextView = {
        let tv = UITextView()
        tv.isScrollEnabled = false
        tv.isEditable = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        return tv
    }()
    private let cache = NSCache<NSString, NSNumber>()

    func height(text: String, width: CGFloat, fontPointSize: Double) -> CGFloat {
        let key = "\(Int(fontPointSize.rounded()))|\(Int(width.rounded()))|\(text)" as NSString
        if let cached = cache.object(forKey: key) {
            return CGFloat(cached.doubleValue)
        }
        measuringView.font = UIFont.systemFont(ofSize: fontPointSize)
        measuringView.text = text
        let fitting = measuringView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = ceil(fitting.height)
        cache.setObject(NSNumber(value: Double(height)), forKey: key)
        return height
    }
}
#endif

import SwiftUI

/// Renders a single paragraph with tap-to-highlight at sentence granularity.
///
/// On iOS the paragraph is drawn by a self-sizing `UITextView` so a tap can be
/// hit-tested to the exact character and mapped to the sentence that contains it
/// (`SentenceLocator`). Only that sentence highlights and is emitted as the TTS
/// utterance. This is the "real UITextView/TextKit path" the project requires before
/// doing any sub-paragraph hit-testing - it replaces the old, unreliable pixel math.
///
/// On macOS (no UIKit) it falls back to a plain `Text` that emits the whole paragraph.
struct SentenceTapOverlay: View {
    let text: String
    let paragraphIndex: Int
    let tappedSentenceRange: NSRange?
    let fontPointSize: Double
    let onSentenceTap: (NSRange, String) -> Void

    var body: some View {
        #if canImport(UIKit)
        SelectableParagraphTextView(
            text: text,
            highlightRange: tappedSentenceRange,
            fontPointSize: fontPointSize,
            onSentenceTap: onSentenceTap
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
/// background highlight on `highlightRange`, and reports the tapped sentence range/text.
struct SelectableParagraphTextView: UIViewRepresentable {
    let text: String
    let highlightRange: NSRange?
    let fontPointSize: Double
    let onSentenceTap: (NSRange, String) -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isScrollEnabled = false
        textView.isEditable = false
        // We do our own tap handling; system text selection would swallow taps.
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
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.text = text
        context.coordinator.onSentenceTap = onSentenceTap

        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: fontPointSize),
                .foregroundColor: UIColor.label
            ]
        )
        if let range = highlightRange, range.location != NSNotFound,
           NSMaxRange(range) <= (text as NSString).length {
            attributed.addAttribute(
                .backgroundColor,
                value: UIColor.systemYellow.withAlphaComponent(0.35),
                range: range
            )
        }
        uiView.attributedText = attributed
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0, width.isFinite else { return nil }
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitting.height))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text, onSentenceTap: onSentenceTap)
    }

    final class Coordinator: NSObject {
        var text: String
        var onSentenceTap: (NSRange, String) -> Void

        init(text: String, onSentenceTap: @escaping (NSRange, String) -> Void) {
            self.text = text
            self.onSentenceTap = onSentenceTap
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView = gesture.view as? UITextView else { return }
            let nsText = text as NSString
            guard nsText.length > 0 else { return }

            let point = gesture.location(in: textView)
            let adjusted = CGPoint(
                x: point.x - textView.textContainerInset.left,
                y: point.y - textView.textContainerInset.top
            )
            var fraction: CGFloat = 0
            // Accessing `layoutManager` opts the text view into TextKit 1, which gives a
            // reliable character hit-test. This is the supported path for index lookup.
            var index = textView.layoutManager.characterIndex(
                for: adjusted,
                in: textView.textContainer,
                fractionOfDistanceBetweenInsertionPoints: &fraction
            )
            if index >= nsText.length { index = nsText.length - 1 }

            let ranges = SentenceLocator.buildSentenceRanges(for: text)
            guard !ranges.isEmpty else {
                let full = NSRange(location: 0, length: nsText.length)
                onSentenceTap(full, text)
                return
            }
            let hit = ranges.first { NSLocationInRange(index, $0) } ?? ranges.last
            guard let sentenceRange = hit else { return }
            let sentence = nsText.substring(with: sentenceRange)
            onSentenceTap(sentenceRange, sentence)
        }
    }
}
#endif

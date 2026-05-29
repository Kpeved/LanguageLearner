import SwiftUI

/// Renders a single paragraph with tap-to-highlight.
/// Tapping anywhere in the paragraph emits the whole paragraph as the "sentence".
/// Paragraph-level (not sentence-level) granularity is intentional: it avoids the
/// pixel-math heuristic that previously dropped or mis-routed taps, and it pairs
/// well with the translation panel which shows the whole native chapter centred
/// on the mapped paragraph anyway.
struct SentenceTapOverlay: View {
    let text: String
    let paragraphIndex: Int
    let tappedSentenceRange: NSRange?
    let fontPointSize: Double
    let onSentenceTap: (NSRange, String) -> Void

    private var isTapped: Bool { tappedSentenceRange != nil }

    var body: some View {
        Text(text)
            .font(.system(size: fontPointSize))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isTapped ? Color.yellow.opacity(0.35) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                let fullRange = NSRange(location: 0, length: (text as NSString).length)
                onSentenceTap(fullRange, text)
            }
    }
}

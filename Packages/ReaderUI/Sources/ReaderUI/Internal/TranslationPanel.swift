import SwiftUI
import Alignment
import EPUBKit

/// Bottom panel showing the full native chapter with the mapped paragraph centred and highlighted.
/// Smaller, swipe-to-dismiss, with a prominent replay control.
struct TranslationPanel: View {

    let nativeChapter: EPUBChapter?
    let centreParagraphIndex: Int
    let highlightRange: TargetParagraphRange?
    /// Sentence-level highlights resolved by the fine alignment layer. When non-empty,
    /// only these sub-paragraph ranges are highlighted; otherwise the panel falls back to
    /// tinting the whole `highlightRange` paragraphs while the refinement is still running.
    let sentenceHighlights: [SentenceHighlight]
    @Binding var settings: ReaderSettings
    /// True when in "play" mode (button shows a pause glyph). False when paused.
    let isPlaying: Bool
    let onPlayPause: () -> Void
    let onSync: () -> Void
    let onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let panelHeight = min(geometry.size.height * 0.55, 460)
            panel(maxHeight: panelHeight)
                .frame(maxWidth: .infinity, alignment: .bottom)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .offset(y: max(0, dragOffset))
                .gesture(swipeDownGesture(panelHeight: panelHeight))
        }
    }

    @ViewBuilder
    private func panel(maxHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            handleAndHeader

            // Full native chapter, centred on the mapped paragraph
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let chapter = nativeChapter {
                            ForEach(Array(chapter.paragraphs.enumerated()), id: \.offset) { index, text in
                                Text(paragraphText(text, paragraphIndex: index))
                                    .font(.system(size: 15))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(paragraphTint(index)
                                                  ? Color.accentColor.opacity(0.22)
                                                  : Color.clear)
                                    )
                                    .id(index)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                }
                .task(id: centreParagraphIndex) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(centreParagraphIndex, anchor: .center)
                    }
                }
            }

            // Rate slider (Speech speed)
            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: "tortoise")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                    Slider(value: $settings.ttsRate, in: 0.3...1.0, step: 0.05)
                    Image(systemName: "hare")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                Text("Speech speed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
        .frame(maxHeight: maxHeight)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(platformBackground))
                .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: -4)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private var handleAndHeader: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 40, height: 5)
                .padding(.top, 8)

            HStack(alignment: .center, spacing: 16) {
                // Sync button (left)
                Button(action: onSync) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.secondary.opacity(0.15)))
                }
                .accessibilityLabel("Sync chapters")

                Spacer()

                // Title and chapter info
                VStack(spacing: 1) {
                    Text("Translation")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let title = nativeChapter?.title, !title.isEmpty {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)

                Spacer()

                // Play / pause button (right, prominent)
                Button(action: onPlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.accentColor))
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
            }
            .padding(.horizontal, 14)
        }
    }

    private func swipeDownGesture(panelHeight: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if value.translation.height > 0 {
                    dragOffset = value.translation.height
                }
            }
            .onEnded { value in
                let dismissThreshold = panelHeight / 3
                if value.translation.height > dismissThreshold || value.predictedEndTranslation.height > dismissThreshold * 2 {
                    onDismiss()
                }
                withAnimation(.easeOut(duration: 0.2)) {
                    dragOffset = 0
                }
            }
    }

    /// Whole-paragraph tint, used only as the pre-refinement fallback. Once sentence
    /// highlights exist they carry the emphasis instead, so the paragraph tint is dropped.
    private func paragraphTint(_ index: Int) -> Bool {
        guard sentenceHighlights.isEmpty else { return false }
        if let range = highlightRange {
            return range.contains(index)
        }
        return index == centreParagraphIndex
    }

    /// Builds the paragraph's display string, drawing a background behind any sentence
    /// ranges resolved for this paragraph.
    private func paragraphText(_ text: String, paragraphIndex: Int) -> AttributedString {
        var attributed = AttributedString(text)
        let ranges = sentenceHighlights
            .filter { $0.paragraphIndex == paragraphIndex }
            .map(\.range)
        let nsText = text as NSString
        for range in ranges {
            guard range.location != NSNotFound,
                  NSMaxRange(range) <= nsText.length,
                  let stringRange = Range(range, in: text),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(stringRange.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].backgroundColor = Color.accentColor.opacity(0.30)
        }
        return attributed
    }

    private var platformBackground: Color {
        #if canImport(UIKit)
        return Color(UIColor.systemBackground)
        #else
        return Color(NSColor.windowBackgroundColor)
        #endif
    }
}

import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// Floating card shown above the reading text after a long-press word selection. It
/// translates the selected word or phrase from the target (learning) language into the
/// native (second book) language using Apple's on-device Translation framework, so it
/// works offline once the language pack is downloaded.
struct WordTranslationBalloon: View {
    let text: String
    /// BCP-47 code of the target/learning language (the selected word's language).
    let sourceLanguage: String
    /// BCP-47 code of the native language to translate into.
    let targetLanguage: String
    /// Selection bounding rect in global (window) coordinates.
    let anchorInGlobal: CGRect
    /// The reader content's frame in global coordinates, used to convert the anchor to
    /// the overlay's local space.
    let containerFrame: CGRect
    let onClose: () -> Void

    private let cardWidth: CGFloat = 280

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Tap anywhere outside the card to dismiss.
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            GeometryReader { geo in
                let local = CGRect(
                    x: anchorInGlobal.minX - containerFrame.minX,
                    y: anchorInGlobal.minY - containerFrame.minY,
                    width: anchorInGlobal.width,
                    height: anchorInGlobal.height
                )
                let x = min(max(8, local.midX - cardWidth / 2), max(8, geo.size.width - cardWidth - 8))
                let y = min(local.maxY + 8, max(8, geo.size.height - 120))
                card
                    .frame(width: cardWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: x, y: y)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Close translation")
            }
            Divider()
            translationContent
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(platformBackground))
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
        )
    }

    @ViewBuilder
    private var translationContent: some View {
        #if canImport(Translation)
        if #available(iOS 18.0, macOS 15.0, *), !sourceLanguage.isEmpty, !targetLanguage.isEmpty {
            TranslatedText(text: text, source: sourceLanguage, target: targetLanguage)
        } else {
            unavailable
        }
        #else
        unavailable
        #endif
    }

    private var unavailable: some View {
        Text("Offline translation needs iOS 18 or later.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var platformBackground: PlatformColor {
        #if canImport(UIKit)
        return UIColor.systemBackground
        #else
        return NSColor.windowBackgroundColor
        #endif
    }
}

#if canImport(UIKit)
import UIKit
private typealias PlatformColor = UIColor
#else
import AppKit
private typealias PlatformColor = NSColor
#endif

#if canImport(Translation)
/// Drives a single offline translation of `text` from `source` to `target`. Recreated per
/// selection (the parent keys it by the selected text), so `onAppear` starts each request.
@available(iOS 18.0, macOS 15.0, *)
private struct TranslatedText: View {
    let text: String
    let source: String
    let target: String

    @State private var configuration: TranslationSession.Configuration?
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        Group {
            if let result {
                Text(result)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            } else if failed {
                Text("Couldn't translate offline. The language pack may need downloading in Settings > Translate.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Translating...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .translationTask(configuration) { session in
            do {
                let response = try await session.translate(text)
                result = response.targetText
            } catch {
                failed = true
            }
        }
        .onAppear {
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: source),
                target: Locale.Language(identifier: target)
            )
        }
    }
}
#endif

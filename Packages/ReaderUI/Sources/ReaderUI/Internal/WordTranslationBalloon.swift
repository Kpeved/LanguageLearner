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
    /// Whether this exact selection has already been saved to the vocabulary deck.
    let isSaved: Bool
    /// Invoked with the resolved translation when the user taps Save.
    let onSave: (String) -> Void
    let onClose: () -> Void

    /// The translation once it resolves, used to enable Save and pass the text up.
    @State private var resolvedTranslation: String?

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
                Button {
                    if let resolvedTranslation { onSave(resolvedTranslation) }
                } label: {
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 17))
                        .foregroundStyle(isSaved ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .disabled(resolvedTranslation == nil || isSaved)
                .accessibilityLabel(isSaved ? "Saved to deck" : "Save to deck")
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
            TranslatedText(text: text, source: sourceLanguage, target: targetLanguage) { translation in
                resolvedTranslation = translation
            }
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
/// The outcome of attempting a single offline translation, used to drive the balloon UI.
@available(iOS 18.0, macOS 15.0, *)
private enum TranslationState {
    case translating
    case done(String)
    /// Source and target are the same language, so there is nothing to translate.
    case sameLanguage
    /// Apple's on-device Translation does not support this language pair.
    case unsupported(source: String, target: String)
    /// A different failure (download declined, runtime error). Carries a description.
    case failed(String)
}

/// Drives a single offline translation of `text` from `source` to `target`. Recreated per
/// selection (the parent keys it by the selected text), so `onAppear` starts each request.
///
/// Apple's Translation framework downloads language packs through a system sheet that it
/// presents itself the first time a supported-but-not-installed pair is used. We surface
/// that flow by checking `LanguageAvailability` up front and calling `prepareTranslation()`
/// (which triggers the download UI) before translating, rather than letting `translate()`
/// throw an opaque error when a pack is missing.
@available(iOS 18.0, macOS 15.0, *)
private struct TranslatedText: View {
    let text: String
    let source: String
    let target: String
    /// Reports the resolved translation up so the balloon can offer Save.
    let onResult: (String) -> Void

    @State private var configuration: TranslationSession.Configuration?
    @State private var state: TranslationState = .translating

    var body: some View {
        Group {
            switch state {
            case .done(let result):
                Text(result)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            case .translating:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Translating...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .sameLanguage:
                Text("Both books are in the same language, so there is nothing to translate.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .unsupported(let src, let tgt):
                Text("On-device translation isn't available for \(languageName(src)) to \(languageName(tgt)).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Couldn't translate offline.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { retry() }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderless)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .translationTask(configuration) { session in
            await translate(using: session)
        }
        .onAppear {
            let src = Locale.Language(identifier: source)
            let tgt = Locale.Language(identifier: target)
            if src.languageCode == tgt.languageCode {
                state = .sameLanguage
                return
            }
            configuration = TranslationSession.Configuration(source: src, target: tgt)
        }
    }

    private func translate(using session: TranslationSession) async {
        let src = Locale.Language(identifier: source)
        let tgt = Locale.Language(identifier: target)
        do {
            let status = await LanguageAvailability().status(from: src, to: tgt)
            switch status {
            case .unsupported:
                state = .unsupported(source: source, target: target)
                return
            case .supported:
                // Pack not yet installed: this presents Apple's download sheet.
                try await session.prepareTranslation()
            case .installed:
                break
            @unknown default:
                break
            }
            let response = try await session.translate(text)
            state = .done(response.targetText)
            onResult(response.targetText)
        } catch {
            NSLog("[WordTranslation] failed %@ -> %@: %@", source, target, String(describing: error))
            state = .failed("\(source) to \(target): \(error.localizedDescription)")
        }
    }

    /// Re-runs the translation request. `translationTask` only fires when the configuration's
    /// identity changes, so we rebuild it (Apple's `invalidate()` is the documented trigger).
    private func retry() {
        state = .translating
        if var config = configuration {
            config.invalidate()
            configuration = config
        } else {
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: source),
                target: Locale.Language(identifier: target)
            )
        }
    }

    /// Human-readable language name for the given BCP-47 code, falling back to the code.
    private func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}
#endif

import Foundation
import NaturalLanguage

/// Reduces an inflected word to its dictionary form so vocabulary cards dedup on the
/// lemma rather than each surface form. Offline, via `NLTagger`.
///
/// Lemmatization is the weak link (homographs, separable verbs, languages without
/// inflection), so callers must keep the original surface form: a poor lemma stays
/// recoverable. Multi-word phrases are passed through unchanged.
public enum Lemmatizer {

    public struct Analysis: Sendable, Equatable {
        /// Dictionary form, lowercased. Falls back to the lowercased surface form.
        public let lemma: String
        /// Coarse part of speech (e.g. "Noun", "Verb"), if the tagger supplied one.
        public let partOfSpeech: String?

        public init(lemma: String, partOfSpeech: String?) {
            self.lemma = lemma
            self.partOfSpeech = partOfSpeech
        }
    }

    /// Analyse a single word in the given BCP-47 language. For phrases (anything with
    /// internal whitespace) the lemma is the trimmed phrase itself.
    public static func analyze(word: String, language: String) -> Analysis {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.lowercased()
        guard !trimmed.isEmpty else { return Analysis(lemma: fallback, partOfSpeech: nil) }

        // Phrases: no reliable single lemma, keep verbatim.
        if trimmed.contains(where: { $0.isWhitespace }) {
            return Analysis(lemma: fallback, partOfSpeech: nil)
        }

        let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass])
        tagger.string = trimmed
        if let nl = nlLanguage(from: language) {
            tagger.setLanguage(nl, range: trimmed.startIndex..<trimmed.endIndex)
        }

        let fullRange = trimmed.startIndex..<trimmed.endIndex
        var lemma: String?
        var pos: String?

        tagger.enumerateTags(in: fullRange, unit: .word, scheme: .lemma, options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            if let tag, !tag.rawValue.isEmpty {
                lemma = tag.rawValue
                return false
            }
            return true
        }
        tagger.enumerateTags(in: fullRange, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            if let tag, !tag.rawValue.isEmpty {
                pos = tag.rawValue
                return false
            }
            return true
        }

        let resolved = (lemma?.isEmpty == false) ? lemma!.lowercased() : fallback
        return Analysis(lemma: resolved, partOfSpeech: pos)
    }

    /// Maps a BCP-47 code (possibly region-qualified, e.g. "pt-BR") to an `NLLanguage`.
    private static func nlLanguage(from bcp47: String) -> NLLanguage? {
        guard !bcp47.isEmpty else { return nil }
        let base = bcp47.split(separator: "-").first.map(String.init) ?? bcp47
        let candidate = NLLanguage(rawValue: base)
        // NLLanguage accepts any raw value; only treat it as valid if recognised.
        return NLLanguage.allKnown.contains(candidate) ? candidate : nil
    }
}

private extension NLLanguage {
    /// The set of languages NLTagger can meaningfully handle. Used to avoid feeding it
    /// an unrecognised code, which would silently produce empty lemmas.
    static var allKnown: Set<NLLanguage> {
        [
            .english, .spanish, .french, .german, .italian, .portuguese, .dutch,
            .russian, .ukrainian, .polish, .czech, .bulgarian, .croatian, .romanian,
            .swedish, .norwegian, .danish, .finnish, .hungarian, .greek, .turkish,
            .simplifiedChinese, .traditionalChinese, .japanese, .korean, .vietnamese,
            .thai, .arabic, .hebrew, .hindi, .indonesian, .malay, .persian, .catalan
        ]
    }
}

import Foundation
import NaturalLanguage

/// Builds and caches a sentence index per paragraph using `NLTokenizer(.sentence)`.
/// Access is not thread-safe; callers must ensure single-threaded (main-actor) use.
final class SentenceLocator {

    // MARK: - Cache

    private var cache: [Int: [NSRange]] = [:]

    // MARK: - Interface

    /// Returns sentence ranges for the given paragraph, building them lazily on first access.
    func sentenceRanges(for paragraphIndex: Int, in text: String) -> [NSRange] {
        if let cached = cache[paragraphIndex] {
            return cached
        }
        let ranges = Self.buildSentenceRanges(for: text)
        cache[paragraphIndex] = ranges
        return ranges
    }

    /// Given a character offset within the paragraph text, returns the sentence range
    /// that contains it, or nil if the offset is out of bounds or the text has no sentences.
    func sentenceRange(atOffset offset: Int, in paragraphIndex: Int, text: String) -> NSRange? {
        let ranges = sentenceRanges(for: paragraphIndex, in: text)
        return ranges.first { NSLocationInRange(offset, $0) }
            ?? (ranges.isEmpty ? nil : ranges.last)
    }

    /// Clears the cached tokenisation for all paragraphs.
    func invalidateAll() {
        cache.removeAll()
    }

    // MARK: - Building

    static func buildSentenceRanges(for text: String) -> [NSRange] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges: [NSRange] = []
        let fullRange = text.startIndex..<text.endIndex
        tokenizer.enumerateTokens(in: fullRange) { tokenRange, _ in
            let nsRange = NSRange(tokenRange, in: text)
            ranges.append(nsRange)
            return true
        }
        return ranges
    }
}

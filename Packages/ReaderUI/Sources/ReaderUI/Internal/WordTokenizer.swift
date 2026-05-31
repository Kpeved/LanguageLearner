import Foundation
import NaturalLanguage

/// Word-boundary helpers for long-press selection. Uses `NLTokenizer(.word)` so the
/// boundaries respect the script of the text (Latin, Cyrillic, CJK, etc.) and stay
/// offline. Access is cheap enough to run per drag update on a single paragraph.
enum WordTokenizer {

    /// Returns the word range containing `offset`. If the offset falls on whitespace or
    /// punctuation, the nearest word is returned. Returns nil when the text has no words.
    static func wordRange(atOffset offset: Int, in text: String) -> NSRange? {
        let tokens = wordRanges(in: text)
        guard !tokens.isEmpty else { return nil }
        if let hit = tokens.first(where: { NSLocationInRange(offset, $0) }) {
            return hit
        }
        return tokens.min(by: { distance($0, to: offset) < distance($1, to: offset) })
    }

    /// Smallest range covering both word ranges (the selection span between an anchor word
    /// and the word currently under the finger).
    static func unite(_ a: NSRange, _ b: NSRange) -> NSRange {
        let lower = min(a.location, b.location)
        let upper = max(NSMaxRange(a), NSMaxRange(b))
        return NSRange(location: lower, length: upper - lower)
    }

    static func wordRanges(in text: String) -> [NSRange] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var ranges: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { tokenRange, _ in
            ranges.append(NSRange(tokenRange, in: text))
            return true
        }
        return ranges
    }

    private static func distance(_ range: NSRange, to offset: Int) -> Int {
        if offset < range.location { return range.location - offset }
        if offset > NSMaxRange(range) { return offset - NSMaxRange(range) }
        return 0
    }
}

import Foundation

public struct ParagraphIndex: Hashable, Sendable, Codable {
    public let chapterIndex: Int
    public let paragraphIndex: Int

    public init(chapterIndex: Int, paragraphIndex: Int) {
        self.chapterIndex = chapterIndex
        self.paragraphIndex = paragraphIndex
    }
}

public struct ParagraphRange: Sendable, Equatable, Codable {
    public let start: ParagraphIndex
    public let end: ParagraphIndex

    public init(start: ParagraphIndex, end: ParagraphIndex) {
        self.start = start
        self.end = end
    }
}

/// Cumulative character offsets per paragraph, precomputed at import time.
/// `perChapterCumulative[c][p]` is the number of characters before paragraph `p` of chapter `c`,
/// measured within that chapter's scope. Each inner array has length `paragraphCount + 1`, so
/// the last value equals the chapter total.
public struct AlignmentProfile: Codable, Sendable, Equatable {
    public let perChapterCumulative: [[Int]]
    public let perChapterTotals: [Int]
    public let bookTotal: Int

    public init(perChapterCumulative: [[Int]], perChapterTotals: [Int], bookTotal: Int) {
        self.perChapterCumulative = perChapterCumulative
        self.perChapterTotals = perChapterTotals
        self.bookTotal = bookTotal
    }
}

public enum AlignmentPolicy: Sendable, Equatable, Codable {
    case chapterAnchored
    case wholeBook
}

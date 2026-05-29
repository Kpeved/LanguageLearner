import Foundation

public protocol AlignmentEngine: Sendable {
    static func profile(for chapters: [[String]]) -> AlignmentProfile
    static func policy(source: AlignmentProfile, target: AlignmentProfile) -> AlignmentPolicy
    static func mapParagraph(_ p: ParagraphIndex,
                             from source: AlignmentProfile,
                             to target: AlignmentProfile,
                             policy: AlignmentPolicy,
                             offset: Int) -> ParagraphIndex
    static func window(around centre: ParagraphIndex,
                       radius: Int,
                       in target: AlignmentProfile,
                       policy: AlignmentPolicy) -> ParagraphRange
}

public enum DefaultAlignmentEngine: AlignmentEngine {

    public static func profile(for chapters: [[String]]) -> AlignmentProfile {
        var perChapterCumulative: [[Int]] = []
        perChapterCumulative.reserveCapacity(chapters.count)
        var perChapterTotals: [Int] = []
        perChapterTotals.reserveCapacity(chapters.count)
        var bookTotal = 0

        for chapter in chapters {
            var cumulative: [Int] = [0]
            cumulative.reserveCapacity(chapter.count + 1)
            var running = 0
            for paragraph in chapter {
                running += paragraph.count
                cumulative.append(running)
            }
            perChapterCumulative.append(cumulative)
            perChapterTotals.append(running)
            bookTotal += running
        }

        return AlignmentProfile(
            perChapterCumulative: perChapterCumulative,
            perChapterTotals: perChapterTotals,
            bookTotal: bookTotal
        )
    }

    public static func policy(source: AlignmentProfile, target: AlignmentProfile) -> AlignmentPolicy {
        if source.perChapterCumulative.count > 0,
           source.perChapterCumulative.count == target.perChapterCumulative.count {
            return .chapterAnchored
        }
        return .wholeBook
    }

    public static func mapParagraph(_ p: ParagraphIndex,
                                    from source: AlignmentProfile,
                                    to target: AlignmentProfile,
                                    policy: AlignmentPolicy,
                                    offset: Int = 0) -> ParagraphIndex {
        guard !source.perChapterCumulative.isEmpty,
              !target.perChapterCumulative.isEmpty,
              p.chapterIndex >= 0,
              p.chapterIndex < source.perChapterCumulative.count else {
            return ParagraphIndex(chapterIndex: 0, paragraphIndex: 0)
        }

        let sourceChapter = source.perChapterCumulative[p.chapterIndex]
        let sourceChapterTotal = source.perChapterTotals[p.chapterIndex]
        let pIndex = clamp(p.paragraphIndex, lower: 0, upper: max(0, sourceChapter.count - 2))

        // Empty source chapter: nothing to map from; treat as zero offset.
        let sourceParagraphCentre: Double
        if sourceChapter.count >= 2 {
            let lo = sourceChapter[pIndex]
            let hi = sourceChapter[pIndex + 1]
            sourceParagraphCentre = Double(lo + hi) / 2.0
        } else {
            sourceParagraphCentre = 0
        }

        switch policy {
        case .chapterAnchored:
            // Same chapter index on the target side, with optional shift applied.
            let targetChapterIndex = clamp(p.chapterIndex + offset, lower: 0, upper: target.perChapterCumulative.count - 1)
            let targetChapter = target.perChapterCumulative[targetChapterIndex]
            let targetParagraphCount = max(0, targetChapter.count - 1)
            let sourceParagraphCount = max(0, sourceChapter.count - 1)
            _ = sourceParagraphCentre // unused in this branch

            guard targetParagraphCount > 0, sourceParagraphCount > 0 else {
                return ParagraphIndex(chapterIndex: targetChapterIndex, paragraphIndex: 0)
            }

            // Paragraph-index proportional. Chapter-anchored mode assumes structural
            // correspondence between source and target, so consecutive source paragraphs
            // should map to consecutive (or near-consecutive) target paragraphs.
            // Character-based mapping caused large jumps when one language had longer
            // paragraphs than the other.
            let pClamped = clamp(p.paragraphIndex, lower: 0, upper: sourceParagraphCount - 1)
            let fraction = (Double(pClamped) + 0.5) / Double(sourceParagraphCount)
            let paragraphFloat = fraction * Double(targetParagraphCount)
            let paragraph = clamp(Int(paragraphFloat), lower: 0, upper: targetParagraphCount - 1)
            return ParagraphIndex(chapterIndex: targetChapterIndex, paragraphIndex: paragraph)

        case .wholeBook:
            // Compute source global centre.
            var sourcePrefix = 0
            for c in 0..<p.chapterIndex { sourcePrefix += source.perChapterTotals[c] }
            let globalSource = Double(sourcePrefix) + sourceParagraphCentre

            let sourceBookTotal = source.bookTotal
            let targetBookTotal = target.bookTotal

            guard sourceBookTotal > 0, targetBookTotal > 0 else {
                return ParagraphIndex(chapterIndex: 0, paragraphIndex: 0)
            }

            let fraction = globalSource / Double(sourceBookTotal)
            let targetGlobal = Int((fraction * Double(targetBookTotal)).rounded())

            // Locate the target chapter via cumulative chapter totals.
            var chapterCumulative: [Int] = [0]
            chapterCumulative.reserveCapacity(target.perChapterTotals.count + 1)
            var run = 0
            for total in target.perChapterTotals {
                run += total
                chapterCumulative.append(run)
            }
            let chapterIdx = BinarySearch.bucket(value: min(targetGlobal, run - 1), in: chapterCumulative) ?? 0
            let withinChapterOffset = targetGlobal - chapterCumulative[chapterIdx]

            let targetChapter = target.perChapterCumulative[chapterIdx]
            let targetParagraphCount = max(0, targetChapter.count - 1)
            guard targetParagraphCount > 0 else {
                return ParagraphIndex(chapterIndex: chapterIdx, paragraphIndex: 0)
            }
            let paragraph = BinarySearch.bucket(value: withinChapterOffset, in: targetChapter)
                ?? (targetParagraphCount - 1)
            return ParagraphIndex(chapterIndex: chapterIdx,
                                  paragraphIndex: clamp(paragraph, lower: 0, upper: targetParagraphCount - 1))
        }
    }

    public static func window(around centre: ParagraphIndex,
                              radius: Int,
                              in target: AlignmentProfile,
                              policy: AlignmentPolicy) -> ParagraphRange {
        let r = max(0, radius)
        let chapterIdx = clamp(centre.chapterIndex,
                               lower: 0,
                               upper: max(0, target.perChapterCumulative.count - 1))
        let chapterParagraphCount: Int
        if target.perChapterCumulative.indices.contains(chapterIdx) {
            chapterParagraphCount = max(0, target.perChapterCumulative[chapterIdx].count - 1)
        } else {
            chapterParagraphCount = 0
        }

        guard chapterParagraphCount > 0 else {
            let idx = ParagraphIndex(chapterIndex: chapterIdx, paragraphIndex: 0)
            return ParagraphRange(start: idx, end: idx)
        }

        let centreParagraph = clamp(centre.paragraphIndex, lower: 0, upper: chapterParagraphCount - 1)
        let startP = max(0, centreParagraph - r)
        let endP = min(chapterParagraphCount - 1, centreParagraph + r)
        return ParagraphRange(
            start: ParagraphIndex(chapterIndex: chapterIdx, paragraphIndex: startP),
            end: ParagraphIndex(chapterIndex: chapterIdx, paragraphIndex: endP)
        )
    }

    // MARK: - helpers

    private static func clamp(_ x: Int, lower: Int, upper: Int) -> Int {
        if upper < lower { return lower }
        return min(max(x, lower), upper)
    }
}

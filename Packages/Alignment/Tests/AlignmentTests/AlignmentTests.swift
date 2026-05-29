import Testing
@testable import Alignment

@Suite("Alignment profile")
struct AlignmentProfileTests {

    @Test func cumulativeIsMonotonicAndTotalsAreConsistent() {
        let chapters: [[String]] = [
            ["aaa", "bb", "cccc"],
            ["dd", "e"]
        ]
        let p = DefaultAlignmentEngine.profile(for: chapters)

        #expect(p.perChapterCumulative.count == 2)
        #expect(p.perChapterCumulative[0] == [0, 3, 5, 9])
        #expect(p.perChapterCumulative[1] == [0, 2, 3])
        #expect(p.perChapterTotals == [9, 3])
        #expect(p.bookTotal == 12)
        #expect(p.perChapterCumulative[0].last == p.perChapterTotals[0])
        #expect(p.perChapterCumulative[1].last == p.perChapterTotals[1])
    }

    @Test func emptyInputProducesEmptyProfile() {
        let p = DefaultAlignmentEngine.profile(for: [])
        #expect(p.perChapterCumulative.isEmpty)
        #expect(p.perChapterTotals.isEmpty)
        #expect(p.bookTotal == 0)
    }

    @Test func emptyChapterStoresZeroCumulative() {
        let p = DefaultAlignmentEngine.profile(for: [[]])
        #expect(p.perChapterCumulative == [[0]])
        #expect(p.perChapterTotals == [0])
        #expect(p.bookTotal == 0)
    }
}

@Suite("Alignment policy")
struct AlignmentPolicyTests {

    @Test func equalChapterCountsGivesChapterAnchored() {
        let s = DefaultAlignmentEngine.profile(for: [["a"], ["b"], ["c"]])
        let t = DefaultAlignmentEngine.profile(for: [["x"], ["y"], ["z"]])
        #expect(DefaultAlignmentEngine.policy(source: s, target: t) == .chapterAnchored)
    }

    @Test func unequalChapterCountsGivesWholeBook() {
        let s = DefaultAlignmentEngine.profile(for: [["a"], ["b"]])
        let t = DefaultAlignmentEngine.profile(for: [["x"]])
        #expect(DefaultAlignmentEngine.policy(source: s, target: t) == .wholeBook)
    }

    @Test func zeroChaptersGivesWholeBook() {
        let s = DefaultAlignmentEngine.profile(for: [])
        let t = DefaultAlignmentEngine.profile(for: [])
        #expect(DefaultAlignmentEngine.policy(source: s, target: t) == .wholeBook)
    }
}

@Suite("mapParagraph - chapter anchored")
struct MapParagraphAnchoredTests {

    @Test func identicalBooksMapToSameOrAdjacentIndex() {
        let chapters: [[String]] = [
            Array(repeating: "para of about thirty characters!", count: 12),
            Array(repeating: "another paragraph here ~thirty c", count: 8)
        ]
        let profile = DefaultAlignmentEngine.profile(for: chapters)
        let policy = DefaultAlignmentEngine.policy(source: profile, target: profile)
        #expect(policy == .chapterAnchored)

        for c in 0..<chapters.count {
            for p in 0..<chapters[c].count {
                let result = DefaultAlignmentEngine.mapParagraph(
                    ParagraphIndex(chapterIndex: c, paragraphIndex: p),
                    from: profile, to: profile, policy: policy
                )
                #expect(result.chapterIndex == c)
                #expect(abs(result.paragraphIndex - p) <= 1)
            }
        }
    }

    @Test func differentParagraphSizesStillRoundTripCloselyForIdenticalChapters() {
        let chapters: [[String]] = [
            ["short", "medium length paragraph", "this is the longest paragraph by quite a margin indeed"]
        ]
        let profile = DefaultAlignmentEngine.profile(for: chapters)
        let result = DefaultAlignmentEngine.mapParagraph(
            ParagraphIndex(chapterIndex: 0, paragraphIndex: 1),
            from: profile, to: profile, policy: .chapterAnchored
        )
        #expect(result.chapterIndex == 0)
        #expect(abs(result.paragraphIndex - 1) <= 1)
    }
}

@Suite("mapParagraph - whole book")
struct MapParagraphWholeBookTests {

    @Test func firstParagraphMapsToEarlyTarget() {
        // 5 chapters x 10 paragraphs of 10 chars each = 500 chars
        let source = makeUniformBook(chapters: 5, paragraphs: 10, paragraphLen: 10)
        // 10 chapters x 5 paragraphs of 10 chars each = 500 chars
        let target = makeUniformBook(chapters: 10, paragraphs: 5, paragraphLen: 10)

        let policy = DefaultAlignmentEngine.policy(source: source, target: target)
        #expect(policy == .wholeBook)

        let first = DefaultAlignmentEngine.mapParagraph(
            ParagraphIndex(chapterIndex: 0, paragraphIndex: 0),
            from: source, to: target, policy: policy
        )
        // Source paragraph 0 of chapter 0 is at the very front; should map to chapter 0 of target.
        #expect(first.chapterIndex == 0)
        #expect(first.paragraphIndex <= 1)
    }

    @Test func lastParagraphMapsToLateTarget() {
        let source = makeUniformBook(chapters: 5, paragraphs: 10, paragraphLen: 10)
        let target = makeUniformBook(chapters: 10, paragraphs: 5, paragraphLen: 10)

        let last = DefaultAlignmentEngine.mapParagraph(
            ParagraphIndex(chapterIndex: 4, paragraphIndex: 9),
            from: source, to: target, policy: .wholeBook
        )
        #expect(last.chapterIndex >= 8)
        #expect(last.paragraphIndex >= 3)
    }

    @Test func deterministic() {
        let source = makeUniformBook(chapters: 3, paragraphs: 7, paragraphLen: 15)
        let target = makeUniformBook(chapters: 4, paragraphs: 6, paragraphLen: 20)
        let p = ParagraphIndex(chapterIndex: 1, paragraphIndex: 3)
        let a = DefaultAlignmentEngine.mapParagraph(p, from: source, to: target, policy: .wholeBook)
        let b = DefaultAlignmentEngine.mapParagraph(p, from: source, to: target, policy: .wholeBook)
        #expect(a == b)
    }

    @Test func emptyTargetReturnsZero() {
        let source = makeUniformBook(chapters: 2, paragraphs: 3, paragraphLen: 5)
        let target = DefaultAlignmentEngine.profile(for: [])
        let result = DefaultAlignmentEngine.mapParagraph(
            ParagraphIndex(chapterIndex: 0, paragraphIndex: 1),
            from: source, to: target, policy: .wholeBook
        )
        #expect(result == ParagraphIndex(chapterIndex: 0, paragraphIndex: 0))
    }
}

@Suite("window")
struct WindowTests {

    @Test func radiusOneInTheMiddleGivesThreeParagraphs() {
        let profile = makeUniformBook(chapters: 1, paragraphs: 7, paragraphLen: 10)
        let centre = ParagraphIndex(chapterIndex: 0, paragraphIndex: 3)
        let w = DefaultAlignmentEngine.window(around: centre, radius: 1, in: profile, policy: .wholeBook)
        #expect(w.start == ParagraphIndex(chapterIndex: 0, paragraphIndex: 2))
        #expect(w.end == ParagraphIndex(chapterIndex: 0, paragraphIndex: 4))
    }

    @Test func leftClampGivesTwoParagraphs() {
        let profile = makeUniformBook(chapters: 1, paragraphs: 7, paragraphLen: 10)
        let centre = ParagraphIndex(chapterIndex: 0, paragraphIndex: 0)
        let w = DefaultAlignmentEngine.window(around: centre, radius: 1, in: profile, policy: .wholeBook)
        #expect(w.start.paragraphIndex == 0)
        #expect(w.end.paragraphIndex == 1)
    }

    @Test func rightClampGivesTwoParagraphs() {
        let profile = makeUniformBook(chapters: 1, paragraphs: 7, paragraphLen: 10)
        let centre = ParagraphIndex(chapterIndex: 0, paragraphIndex: 6)
        let w = DefaultAlignmentEngine.window(around: centre, radius: 1, in: profile, policy: .wholeBook)
        #expect(w.start.paragraphIndex == 5)
        #expect(w.end.paragraphIndex == 6)
    }

    @Test func emptyChapterReturnsDegenerateRange() {
        let profile = DefaultAlignmentEngine.profile(for: [[]])
        let centre = ParagraphIndex(chapterIndex: 0, paragraphIndex: 0)
        let w = DefaultAlignmentEngine.window(around: centre, radius: 2, in: profile, policy: .wholeBook)
        #expect(w.start == w.end)
        #expect(w.start.chapterIndex == 0)
        #expect(w.start.paragraphIndex == 0)
    }

    @Test func neverCrossesChapterBoundariesEvenInWholeBookMode() {
        let profile = makeUniformBook(chapters: 3, paragraphs: 4, paragraphLen: 10)
        let centre = ParagraphIndex(chapterIndex: 1, paragraphIndex: 3) // last paragraph of chapter 1
        let w = DefaultAlignmentEngine.window(around: centre, radius: 2, in: profile, policy: .wholeBook)
        #expect(w.start.chapterIndex == 1)
        #expect(w.end.chapterIndex == 1)
        #expect(w.end.paragraphIndex == 3) // clamped, does NOT spill into chapter 2
    }
}

// MARK: - helpers

private func makeUniformBook(chapters: Int, paragraphs: Int, paragraphLen: Int) -> AlignmentProfile {
    let paragraph = String(repeating: "x", count: paragraphLen)
    let book: [[String]] = Array(repeating: Array(repeating: paragraph, count: paragraphs), count: chapters)
    return DefaultAlignmentEngine.profile(for: book)
}

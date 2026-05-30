import Testing
import Foundation
@testable import Alignment

// MARK: - Mock embedding provider

/// A mock provider that returns deterministic, low-dimensional vectors. Strings that
/// share a "tag" (set up by the test) embed close together, so we can simulate
/// cross-lingual alignment without loading any model.
struct MockEmbeddingProvider: EmbeddingProvider {
    let dimension: Int = 4

    /// String -> vector. Tests configure this directly.
    let table: [String: [Float]]

    func embed(_ paragraph: String) async throws -> [Float] {
        if let v = table[paragraph] { return v }
        return Array(repeating: 0, count: dimension)
    }
}

@Suite("NeedlemanWunsch")
struct NeedlemanWunschTests {

    @Test func cosineOfIdenticalVectorsIsOne() {
        let v: [Float] = [1, 2, 3, 4]
        #expect(abs(NeedlemanWunsch.cosine(v, v) - 1.0) < 1e-5)
    }

    @Test func cosineOfOrthogonalVectorsIsZero() {
        let a: [Float] = [1, 0, 0, 0]
        let b: [Float] = [0, 1, 0, 0]
        #expect(abs(NeedlemanWunsch.cosine(a, b)) < 1e-5)
    }

    @Test func cosineOfZeroVectorIsZero() {
        let a: [Float] = [0, 0, 0, 0]
        let b: [Float] = [1, 2, 3, 4]
        #expect(NeedlemanWunsch.cosine(a, b) == 0)
    }

    @Test func identityAlignmentForIdenticalSimilarityMatrix() {
        // Perfect diagonal: each source pair perfectly matches the same-index target.
        let sim: [[Float]] = [
            [1, 0, 0],
            [0, 1, 0],
            [0, 0, 1]
        ]
        let result = NeedlemanWunsch.align(similarity: sim)
        #expect(result.count == 3)
        #expect(result[0] == 0...0)
        #expect(result[1] == 1...1)
        #expect(result[2] == 2...2)
    }

    @Test func oneToManyAlignmentForGroupedTargets() {
        // Source paragraph 0 matches targets 0, 1, 2 (e.g. an address block).
        // Source paragraph 1 matches target 3.
        let sim: [[Float]] = [
            [0.9, 0.9, 0.9, 0.1],
            [0.1, 0.1, 0.1, 0.9]
        ]
        let result = NeedlemanWunsch.align(similarity: sim)
        #expect(result.count == 2)
        #expect(result[0] == 0...2)
        #expect(result[1] == 3...3)
    }

    @Test func manyToOneAlignmentForGroupedSources() {
        // Sources 0, 1, 2 (small address lines) all match target 0 (one big block).
        // Source 3 matches target 1.
        let sim: [[Float]] = [
            [0.9, 0.1],
            [0.9, 0.1],
            [0.9, 0.1],
            [0.1, 0.9]
        ]
        let result = NeedlemanWunsch.align(similarity: sim)
        #expect(result.count == 4)
        #expect(result[0] == 0...0)
        #expect(result[1] == 0...0)
        #expect(result[2] == 0...0)
        #expect(result[3] == 1...1)
    }

    @Test func monotonicityIsPreserved() {
        // For any reasonable matrix, returned ranges must be monotone non-decreasing
        // (sources go through targets left-to-right; no zigzag).
        let sim: [[Float]] = [
            [0.9, 0.1, 0.0],
            [0.0, 0.8, 0.1],
            [0.0, 0.0, 0.9]
        ]
        let result = NeedlemanWunsch.align(similarity: sim)
        var lastEnd = -1
        for r in result {
            if let r = r {
                #expect(r.lowerBound >= lastEnd)
                lastEnd = r.upperBound
            }
        }
    }
}

@Suite("ParagraphAlignmentTable")
struct ParagraphAlignmentTableTests {

    @Test func emptyTableReturnsNilForAnyLookup() {
        let table = ParagraphAlignmentTable.empty
        #expect(table.range(forSourceChapter: 0, paragraph: 0) == nil)
        #expect(table.range(forSourceChapter: 5, paragraph: 3) == nil)
    }

    @Test func nilEntryIsReturnedForUnalignedParagraph() {
        let table = ParagraphAlignmentTable(perSourceChapter: [[
            TargetParagraphRange(start: 0, end: 0),
            nil,
            TargetParagraphRange(start: 1, end: 1)
        ]])
        #expect(table.range(forSourceChapter: 0, paragraph: 0) == TargetParagraphRange(start: 0, end: 0))
        #expect(table.range(forSourceChapter: 0, paragraph: 1) == nil)
        #expect(table.range(forSourceChapter: 0, paragraph: 2) == TargetParagraphRange(start: 1, end: 1))
    }

    @Test func codableRoundTrip() throws {
        let table = ParagraphAlignmentTable(perSourceChapter: [
            [TargetParagraphRange(start: 0, end: 2), nil],
            [TargetParagraphRange(start: 3, end: 5)]
        ])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(table)
        let decoded = try PropertyListDecoder().decode(ParagraphAlignmentTable.self, from: data)
        #expect(decoded == table)
    }
}

@Suite("DefaultParagraphAligner with mock embeddings")
struct ParagraphAlignerIntegrationTests {

    @Test func oneSpanishParagraphMapsToFiveEnglishParagraphs() async throws {
        // The "address block" scenario: Spanish has one big paragraph, English has
        // five short ones. All five English share the same embedding tag (addr).
        let addr: [Float] = [1, 0, 0, 0]
        let line: [Float] = [0, 1, 0, 0]
        let provider = MockEmbeddingProvider(table: [
            "Senor H. Potter Alacena Debajo de la Escalera Privet Drive 4 Little Whinging Surrey": addr,
            "El sobre era grueso y pesado.": line,
            "Mr H. Potter": addr,
            "The Cupboard under the Stairs": addr,
            "4 Privet Drive": addr,
            "Little Whinging": addr,
            "Surrey": addr,
            "The envelope was thick and heavy.": line
        ])

        let source: [[String]] = [[
            "Senor H. Potter Alacena Debajo de la Escalera Privet Drive 4 Little Whinging Surrey",
            "El sobre era grueso y pesado."
        ]]
        let target: [[String]] = [[
            "Mr H. Potter",
            "The Cupboard under the Stairs",
            "4 Privet Drive",
            "Little Whinging",
            "Surrey",
            "The envelope was thick and heavy."
        ]]
        let table = try await DefaultParagraphAligner.buildTable(
            source: source,
            target: target,
            chapterOffset: 0,
            provider: provider
        )
        let r = table.range(forSourceChapter: 0, paragraph: 0)
        #expect(r != nil)
        // First source paragraph should align to a range covering all 5 address paragraphs.
        #expect(r?.start == 0)
        #expect(r?.end == 4)
        // Second source paragraph should align to target paragraph 5.
        let r2 = table.range(forSourceChapter: 0, paragraph: 1)
        #expect(r2 == TargetParagraphRange(start: 5, end: 5))
    }

    @Test func identicalParagraphsProduceDiagonalAlignment() async throws {
        let vA: [Float] = [1, 0, 0, 0]
        let vB: [Float] = [0, 1, 0, 0]
        let vC: [Float] = [0, 0, 1, 0]
        let provider = MockEmbeddingProvider(table: [
            "alpha": vA, "beta": vB, "gamma": vC,
            "alfa": vA, "veta": vB, "gama": vC
        ])
        let table = try await DefaultParagraphAligner.buildTable(
            source: [["alpha", "beta", "gamma"]],
            target: [["alfa", "veta", "gama"]],
            chapterOffset: 0,
            provider: provider
        )
        #expect(table.range(forSourceChapter: 0, paragraph: 0) == TargetParagraphRange(start: 0, end: 0))
        #expect(table.range(forSourceChapter: 0, paragraph: 1) == TargetParagraphRange(start: 1, end: 1))
        #expect(table.range(forSourceChapter: 0, paragraph: 2) == TargetParagraphRange(start: 2, end: 2))
    }

    @Test func emptyChaptersProduceEmptyAlignmentRows() async throws {
        let provider = MockEmbeddingProvider(table: [:])
        let table = try await DefaultParagraphAligner.buildTable(
            source: [[], ["only this exists"]],
            target: [["x"], []],
            chapterOffset: 0,
            provider: provider
        )
        #expect(table.perSourceChapter.count == 2)
        #expect(table.perSourceChapter[0].isEmpty)
        // Chapter 1 source has content but target chapter is empty -> single nil entry.
        #expect(table.perSourceChapter[1].count == 1)
        #expect(table.perSourceChapter[1][0] == nil)
    }
}

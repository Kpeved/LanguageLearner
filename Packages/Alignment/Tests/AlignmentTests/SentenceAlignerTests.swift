import Testing
import Foundation
@testable import Alignment

@Suite("SentenceAligner with mock embeddings")
struct SentenceAlignerTests {

    @Test func diagonalSentenceAlignment() async throws {
        let vA: [Float] = [1, 0, 0, 0]
        let vB: [Float] = [0, 1, 0, 0]
        let vC: [Float] = [0, 0, 1, 0]
        let provider = MockEmbeddingProvider(table: [
            "He woke up.": vA, "He looked around.": vB, "Then he left.": vC,
            "Se desperto.": vA, "Miro alrededor.": vB, "Luego se fue.": vC
        ])
        let result = try await SentenceAligner.align(
            source: ["Se desperto.", "Miro alrededor.", "Luego se fue."],
            target: ["He woke up.", "He looked around.", "Then he left."],
            provider: provider
        )
        #expect(result.count == 3)
        #expect(result[0] == TargetParagraphRange(start: 0, end: 0))
        #expect(result[1] == TargetParagraphRange(start: 1, end: 1))
        #expect(result[2] == TargetParagraphRange(start: 2, end: 2))
    }

    @Test func oneSourceSentenceSplitsIntoTwoTargets() async throws {
        // A long source sentence translated as two shorter target sentences.
        let split: [Float] = [1, 0, 0, 0]
        let other: [Float] = [0, 1, 0, 0]
        let provider = MockEmbeddingProvider(table: [
            "Era una manana fria y caminamos juntos.": split,
            "It was a cold morning.": split,
            "We walked together.": split,
            "Fin.": other,
            "The end.": other
        ])
        let result = try await SentenceAligner.align(
            source: ["Era una manana fria y caminamos juntos.", "Fin."],
            target: ["It was a cold morning.", "We walked together.", "The end."],
            provider: provider
        )
        #expect(result.count == 2)
        #expect(result[0] == TargetParagraphRange(start: 0, end: 1))
        #expect(result[1] == TargetParagraphRange(start: 2, end: 2))
    }

    @Test func emptyInputsReturnNilEntries() async throws {
        let provider = MockEmbeddingProvider(table: [:])
        let result = try await SentenceAligner.align(source: ["a", "b"], target: [], provider: provider)
        #expect(result == [nil, nil])
    }
}

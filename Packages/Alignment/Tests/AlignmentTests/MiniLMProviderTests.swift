import Testing
import Foundation
@testable import Alignment

/// Integration tests for the CoreML-backed `MiniLMEmbeddingProvider`. These download
/// (~108 MB once) and compile the model, so they are gated behind `RUN_MODEL_TESTS=1`:
///
///   RUN_MODEL_TESTS=1 swift test --filter MiniLMProviderTests
///
/// They prove the Swift tokenizer + CoreML inference match the Python reference
/// (`tools/convert_minilm_to_coreml.py`) captured in `Resources/fixtures.json`.
@Suite("MiniLM provider", .enabled(if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1"))
struct MiniLMProviderTests {

    struct Fixtures: Codable {
        let dim: Int
        let sentences: [String]
        let embeddings: [[Float]]
    }

    private func loadFixtures() throws -> Fixtures {
        let url = try #require(Bundle.module.url(forResource: "fixtures", withExtension: "json"))
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }

    @Test func embeddingsMatchPythonReference() async throws {
        let fx = try loadFixtures()
        let provider = try await MiniLMEmbeddingProvider.makeShared()
        #expect(provider.dimension == fx.dim)

        for (i, sentence) in fx.sentences.enumerated() {
            let vec = try await provider.embed(sentence)
            let cosine = NeedlemanWunsch.cosine(vec, fx.embeddings[i])
            #expect(cosine > 0.99, "sentence \(i) cosine to reference = \(cosine)")
        }
    }

    @Test func translationsAreCloserThanUnrelated() async throws {
        let fx = try loadFixtures()
        let provider = try await MiniLMEmbeddingProvider.makeShared()
        // Fixtures: 0 = "The cat sat on the mat." (en), 1 = its Spanish translation,
        // 4 = an unrelated English sentence.
        let enCat = try await provider.embed(fx.sentences[0])
        let esCat = try await provider.embed(fx.sentences[1])
        let unrelated = try await provider.embed(fx.sentences[4])
        let translationSim = NeedlemanWunsch.cosine(enCat, esCat)
        let unrelatedSim = NeedlemanWunsch.cosine(enCat, unrelated)
        #expect(translationSim > unrelatedSim + 0.3,
                "translation \(translationSim) should beat unrelated \(unrelatedSim)")
    }
}

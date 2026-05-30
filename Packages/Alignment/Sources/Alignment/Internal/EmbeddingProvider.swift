import Foundation
import NaturalLanguage

/// Computes a single-vector embedding per paragraph in some cross-lingual space.
/// Tests inject mock implementations; production uses `NLContextualEmbeddingProvider`.
protocol EmbeddingProvider: Sendable {
    /// Dimension of the returned vectors. All vectors must have the same dimension.
    var dimension: Int { get }

    /// Embed a single paragraph. Empty/whitespace input may return a zero vector.
    func embed(_ paragraph: String) async throws -> [Float]

    /// Embed many paragraphs at once. Providers backed by a batchable model (CoreML)
    /// override this for a large speedup; the default just maps over `embed`.
    func embedBatch(_ paragraphs: [String]) async throws -> [[Float]]
}

extension EmbeddingProvider {
    func embedBatch(_ paragraphs: [String]) async throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(paragraphs.count)
        for p in paragraphs {
            try Task.checkCancellation()
            out.append(try await embed(p))
        }
        return out
    }
}

/// Wraps `NLContextualEmbedding`. Uses mean pooling over subword token vectors
/// to produce one vector per paragraph. The multilingual Latin/Cyrillic/CJK/Indic/
/// Arabic/Thai models project compatible languages into a shared space, so source
/// and target paragraphs in the same script group can be compared by cosine similarity.
@available(iOS 17.0, macOS 14.0, *)
final class NLContextualEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {

    private let embedding: NLContextualEmbedding
    let language: NLLanguage
    let dimension: Int

    /// Throws if no model is available for the given language or if assets are missing.
    init(language: NLLanguage) async throws {
        guard let model = NLContextualEmbedding(language: language) else {
            throw AlignmentRuntimeError.noEmbeddingForLanguage(language.rawValue)
        }
        self.embedding = model
        self.language = language
        self.dimension = model.dimension

        // Always run the asset request, not just when `hasAvailableAssets` is false:
        // downloaded assets still need an on-device compilation step that `requestAssets`
        // triggers. Skipping it leaves `load()` failing with "requires compilation".
        try await Self.requestAssets(model: model)

        // The model must be loaded into memory before `embeddingResult(for:)` will work.
        // Skipping this is what produces "Failed to load contextual embedding" on the
        // first embed call, which previously failed the whole alignment build silently.
        do {
            try model.load()
        } catch {
            throw AlignmentRuntimeError.assetsUnavailable("Failed to load contextual embedding model: \(error.localizedDescription)")
        }
    }

    func embed(_ paragraph: String) async throws -> [Float] {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return Array(repeating: 0, count: dimension)
        }
        // Cap excessively long paragraphs to a few thousand characters; embedding model
        // truncates internally to `maximumSequenceLength` tokens anyway.
        let capped = String(trimmed.prefix(2_000))

        let result: NLContextualEmbeddingResult
        do {
            result = try embedding.embeddingResult(for: capped, language: language)
        } catch {
            throw AlignmentRuntimeError.embeddingFailed(error.localizedDescription)
        }

        var sum = [Float](repeating: 0, count: dimension)
        var count = 0
        result.enumerateTokenVectors(in: capped.startIndex..<capped.endIndex) { vector, _ in
            for i in 0..<min(vector.count, sum.count) {
                sum[i] += Float(vector[i])
            }
            count += 1
            return true
        }
        guard count > 0 else { return sum }
        let invCount = 1.0 / Float(count)
        for i in 0..<sum.count { sum[i] *= invCount }
        return sum
    }

    private static func requestAssets(model: NLContextualEmbedding) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            model.requestAssets { result, error in
                if let error = error {
                    continuation.resume(throwing: AlignmentRuntimeError.assetsUnavailable(error.localizedDescription))
                    return
                }
                switch result {
                case .available:
                    continuation.resume(returning: ())
                case .notAvailable:
                    continuation.resume(throwing: AlignmentRuntimeError.assetsUnavailable("Model assets not available"))
                case .error:
                    continuation.resume(throwing: AlignmentRuntimeError.assetsUnavailable("Asset request error"))
                @unknown default:
                    continuation.resume(throwing: AlignmentRuntimeError.assetsUnavailable("Unknown asset status"))
                }
            }
        }
    }
}

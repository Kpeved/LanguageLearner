import Foundation
import CoreML
import Tokenizers

/// `EmbeddingProvider` backed by a bundled multilingual sentence encoder
/// (`paraphrase-multilingual-MiniLM-L12-v2`) running on CoreML. Unlike
/// `NLContextualEmbeddingProvider`, one instance embeds every language: the model is
/// cross-lingually aligned, so a paragraph and its translation map to nearby unit
/// vectors and cosine similarity is a strong alignment signal.
///
/// The CoreML graph bakes in attention-masked mean pooling and L2 normalization, so
/// this type only tokenizes, pads to a fixed length, runs the model, and copies the
/// resulting unit vector out.
final class MiniLMEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {

    static let sequenceLength = 128
    /// XLM-R padding id. Padded positions are masked out of pooling, so the exact value
    /// does not affect the output.
    private static let padTokenID: Int32 = 1

    let dimension: Int
    private let model: MLModel
    private let tokenizer: Tokenizer

    /// Loads the CoreML model and tokenizer from a prepared (downloaded + compiled) bundle.
    init(prepared: PreparedModel) async throws {
        let config = MLModelConfiguration()
        // Force the CPU backend. This is an int8-quantized XLM-R encoder with a ~250k-token
        // embedding table. On a physical device, both the ANE (`.all`) and the GPU
        // (`.cpuAndGPU`) decompress that embedding table from int8 into float and re-lay it
        // out for their kernels - a multi-hundred-MB materialization that, combined with the
        // 32-wide batch fan-out below, spikes to ~3GB and gets the app OOM-killed. The CPU
        // backend runs the quantized graph with a true gather (weights stay int8, no
        // one-hot/decompression blow-up), keeping resident memory near the ~500MB the
        // Simulator already proved is the real steady state. The Simulator never reproduced
        // the spike because it has no ANE and isn't memory-pressured. Alignment runs as a
        // background task, so the CPU latency cost is acceptable.
        config.computeUnits = .cpuOnly
        do {
            self.model = try MLModel(contentsOf: prepared.compiledModelURL, configuration: config)
        } catch {
            throw AlignmentRuntimeError.embeddingFailed("Cannot load CoreML model: \(error.localizedDescription)")
        }
        do {
            self.tokenizer = try await AutoTokenizer.from(modelFolder: prepared.tokenizerDirURL)
        } catch {
            throw AlignmentRuntimeError.embeddingFailed("Cannot load tokenizer: \(error.localizedDescription)")
        }

        // Read the output vector length from the model description (384 for MiniLM-L12).
        if let out = model.modelDescription.outputDescriptionsByName["embedding"],
           let shape = out.multiArrayConstraint?.shape,
           let last = shape.last?.intValue {
            self.dimension = last
        } else {
            self.dimension = 384
        }
    }

    /// Convenience: prepare the shared model and build a provider. Translates the internal
    /// `ModelStoreError` into a public `AlignmentRuntimeError` so the diagnostics layer can
    /// surface a readable reason.
    static func makeShared(progress: @Sendable @escaping (ModelPreparePhase) -> Void = { _ in }) async throws -> MiniLMEmbeddingProvider {
        let prepared: PreparedModel
        do {
            prepared = try await ModelStore.shared.prepare(progress: progress)
        } catch let error as ModelStoreError {
            throw AlignmentRuntimeError.assetsUnavailable(describe(error))
        }
        return try await MiniLMEmbeddingProvider(prepared: prepared)
    }

    private static func describe(_ error: ModelStoreError) -> String {
        switch error {
        case .downloadFailed(let detail): return "Model download failed: \(detail)"
        case .unzipFailed(let detail): return "Model unzip failed: \(detail)"
        case .compileFailed(let detail): return "Model compile failed: \(detail)"
        case .missingArtifact(let name): return "Downloaded model is missing \(name)"
        }
    }

    /// Largest number of paragraphs fed to CoreML in one batch. The model is traced with a
    /// fixed `(1, 128)` input shape, so a multi-element `MLArrayBatchProvider` does not run a
    /// real batched kernel - CoreML fans out that many single inferences and allocates their
    /// transient buffers concurrently, multiplying peak memory. Keep this at 1 so peak
    /// memory is one inference's worth; raise only if device profiling shows headroom.
    private static let maxBatch = 1

    func embed(_ paragraph: String) async throws -> [Float] {
        let result = try await embedBatch([paragraph])
        return result.first ?? Array(repeating: 0, count: dimension)
    }

    func embedBatch(_ paragraphs: [String]) async throws -> [[Float]] {
        if paragraphs.isEmpty { return [] }
        var output: [[Float]] = []
        output.reserveCapacity(paragraphs.count)
        var index = 0
        while index < paragraphs.count {
            try Task.checkCancellation()
            let slice = Array(paragraphs[index..<min(index + Self.maxBatch, paragraphs.count)])
            output.append(contentsOf: try runBatch(slice))
            index += slice.count
        }
        return output
    }

    private func runBatch(_ paragraphs: [String]) throws -> [[Float]] {
        var inputs: [MLFeatureProvider] = []
        inputs.reserveCapacity(paragraphs.count)
        do {
            for paragraph in paragraphs {
                let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                let (ids, mask) = tokenize(trimmed)
                let inputIds = try MLMultiArray(shape: [1, NSNumber(value: Self.sequenceLength)], dataType: .int32)
                let attentionMask = try MLMultiArray(shape: [1, NSNumber(value: Self.sequenceLength)], dataType: .int32)
                let idsPtr = inputIds.dataPointer.bindMemory(to: Int32.self, capacity: Self.sequenceLength)
                let maskPtr = attentionMask.dataPointer.bindMemory(to: Int32.self, capacity: Self.sequenceLength)
                for i in 0..<Self.sequenceLength {
                    idsPtr[i] = ids[i]
                    maskPtr[i] = mask[i]
                }
                inputs.append(try MLDictionaryFeatureProvider(dictionary: [
                    "input_ids": inputIds,
                    "attention_mask": attentionMask,
                ]))
            }
        } catch {
            throw AlignmentRuntimeError.embeddingFailed("Cannot build input: \(error.localizedDescription)")
        }

        let outBatch: MLBatchProvider
        do {
            outBatch = try model.predictions(from: MLArrayBatchProvider(array: inputs), options: MLPredictionOptions())
        } catch {
            throw AlignmentRuntimeError.embeddingFailed("Inference failed: \(error.localizedDescription)")
        }

        var results: [[Float]] = []
        results.reserveCapacity(paragraphs.count)
        for i in 0..<outBatch.count {
            guard let value = outBatch.features(at: i).featureValue(for: "embedding")?.multiArrayValue else {
                throw AlignmentRuntimeError.embeddingFailed("Model produced no embedding output")
            }
            var vector = [Float](repeating: 0, count: dimension)
            let count = min(dimension, value.count)
            let ptr = value.dataPointer.bindMemory(to: Float.self, capacity: count)
            for j in 0..<count { vector[j] = ptr[j] }
            results.append(vector)
        }
        return results
    }

    /// Tokenizes with special tokens, truncates to `sequenceLength` (preserving the final
    /// separator token), and pads. Returns fixed-length id and attention-mask arrays.
    private func tokenize(_ text: String) -> (ids: [Int32], mask: [Int32]) {
        var tokenIDs = tokenizer.encode(text: text, addSpecialTokens: true)
        let limit = Self.sequenceLength
        if tokenIDs.count > limit {
            let eos = tokenizer.eosTokenId ?? tokenIDs[tokenIDs.count - 1]
            tokenIDs = Array(tokenIDs.prefix(limit - 1)) + [eos]
        }

        var ids = [Int32](repeating: Self.padTokenID, count: limit)
        var mask = [Int32](repeating: 0, count: limit)
        for (i, token) in tokenIDs.enumerated() {
            ids[i] = Int32(token)
            mask[i] = 1
        }
        return (ids, mask)
    }
}

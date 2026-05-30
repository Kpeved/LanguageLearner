import Foundation

/// Aligns two short sequences of sentences against each other, reusing the same
/// multilingual embedding + Needleman-Wunsch machinery as `DefaultParagraphAligner`
/// but at sentence granularity within an already-matched span.
///
/// This is the fine layer on top of paragraph alignment: paragraph alignment is the
/// coarse, reliable anchor (paragraph boundaries are stable across translations);
/// sentence alignment only runs *within* a paragraph against its already-matched
/// native paragraph range, so a weak sentence match can never route outside that span.
///
/// The provider is cached across calls so repeated taps reuse the warm CoreML model
/// instead of rebuilding it each time.
public enum SentenceAligner {

    private static let providerBox = ProviderBox()

    /// Aligns `source` sentences to `target` sentences.
    ///
    /// - Returns: one entry per source sentence; each is the inclusive range of target
    ///   sentence indices it maps to, or nil when no good match was found. The returned
    ///   array always has `source.count` entries.
    public static func align(source: [String], target: [String]) async throws -> [TargetParagraphRange?] {
        guard !source.isEmpty, !target.isEmpty else {
            return Array(repeating: nil, count: source.count)
        }
        let provider = try await providerBox.shared()
        return try await align(source: source, target: target, provider: provider)
    }

    /// Testable core: aligns using an injected provider.
    static func align(source: [String], target: [String], provider: EmbeddingProvider) async throws -> [TargetParagraphRange?] {
        guard !source.isEmpty, !target.isEmpty else {
            return Array(repeating: nil, count: source.count)
        }
        let sv = try await provider.embedBatch(source)
        let tv = try await provider.embedBatch(target)
        var sim = Array(repeating: Array(repeating: Float(0), count: target.count), count: source.count)
        for i in 0..<source.count {
            for j in 0..<target.count {
                sim[i][j] = NeedlemanWunsch.cosine(sv[i], tv[j])
            }
        }
        let alignment = NeedlemanWunsch.align(similarity: sim)
        return alignment.map { range in
            guard let r = range else { return nil }
            return TargetParagraphRange(start: r.lowerBound, end: r.upperBound)
        }
    }
}

/// Caches a single prepared embedding provider so per-tap sentence alignment does not
/// rebuild the CoreML model and tokenizer on every invocation.
private actor ProviderBox {
    private var provider: MiniLMEmbeddingProvider?

    func shared() async throws -> MiniLMEmbeddingProvider {
        if let provider { return provider }
        let made = try await MiniLMEmbeddingProvider.makeShared()
        provider = made
        return made
    }
}

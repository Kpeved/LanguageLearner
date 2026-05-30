import Foundation
import NaturalLanguage

/// A range of target paragraph indices (inclusive) that a source paragraph aligns to.
public struct TargetParagraphRange: Codable, Sendable, Equatable, Hashable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public var count: Int { end - start + 1 }
    public func contains(_ index: Int) -> Bool { index >= start && index <= end }
}

/// Per-source-chapter, per-source-paragraph mapping into a range of target paragraphs.
/// `perSourceChapter[c][p]` may be nil if the aligner could not match that source paragraph
/// (source-only content: a translator's note that doesn't appear on the native side).
/// `perSourceChapter[c]` may be empty if alignment was skipped for that chapter
/// (e.g. embedding model unavailable for the language).
public struct ParagraphAlignmentTable: Codable, Sendable, Equatable {
    public let perSourceChapter: [[TargetParagraphRange?]]

    public init(perSourceChapter: [[TargetParagraphRange?]]) {
        self.perSourceChapter = perSourceChapter
    }

    public static let empty = ParagraphAlignmentTable(perSourceChapter: [])

    /// Returns the target range for the given source paragraph, or nil if unaligned/missing.
    public func range(forSourceChapter chapter: Int, paragraph: Int) -> TargetParagraphRange? {
        guard chapter >= 0, chapter < perSourceChapter.count else { return nil }
        let chapterMap = perSourceChapter[chapter]
        guard paragraph >= 0, paragraph < chapterMap.count else { return nil }
        return chapterMap[paragraph]
    }
}

/// Errors thrown while building a `ParagraphAlignmentTable`.
public enum AlignmentRuntimeError: Error, Sendable, Equatable {
    case noEmbeddingForLanguage(String)
    case assetsUnavailable(String)
    case embeddingFailed(String)
    case cancelled
}

/// API for computing a per-paragraph alignment between two parsed books.
public protocol ParagraphAligner: Sendable {
    /// Builds a paragraph-to-paragraph-range alignment table for the source against the target.
    /// One alignment row per source chapter. Chapters whose source/target lengths are zero
    /// produce empty inner arrays; otherwise the algorithm runs per-chapter independently.
    ///
    /// - Parameters:
    ///   - source: parsed source-language paragraphs grouped by chapter
    ///   - sourceLanguage: BCP-47 tag (e.g. "es")
    ///   - target: parsed target-language paragraphs grouped by chapter
    ///   - targetLanguage: BCP-47 tag (e.g. "en")
    ///   - chapterOffset: integer shift applied to source chapter index when looking up
    ///     the corresponding target chapter. Same semantics as `AlignmentEngine.mapParagraph`.
    ///   - progress: called from background actor with values in 0...1 as chapters complete.
    static func buildTable(
        source: [[String]],
        sourceLanguage: String,
        target: [[String]],
        targetLanguage: String,
        chapterOffset: Int,
        progress: @Sendable (Double) -> Void
    ) async throws -> ParagraphAlignmentTable
}

/// Default implementation backed by `NLContextualEmbedding` and a Needleman-Wunsch
/// dynamic programming pass. Both books must be in languages supported by the same
/// model script group (Latin, Cyrillic, CJK, Indic, Arabic, Thai); otherwise the
/// resulting table will fall back to empty for affected chapters.
public enum DefaultParagraphAligner: ParagraphAligner {

    public static func buildTable(
        source: [[String]],
        sourceLanguage: String,
        target: [[String]],
        targetLanguage: String,
        chapterOffset: Int = 0,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> ParagraphAlignmentTable {
        guard #available(iOS 17.0, macOS 14.0, *) else {
            throw AlignmentRuntimeError.noEmbeddingForLanguage("requires iOS 17+/macOS 14+")
        }
        // One multilingual sentence encoder embeds both languages; it is cross-lingually
        // aligned, so source/target language tags are advisory and unused here. The model
        // is downloaded and compiled on first use (see ModelStore).
        let provider = try await MiniLMEmbeddingProvider.makeShared { phase in
            NSLog("[Alignment] model prepare: %@", String(describing: phase))
        }
        return try await buildTable(
            source: source,
            target: target,
            chapterOffset: chapterOffset,
            provider: provider,
            progress: progress
        )
    }

    /// Builds an alignment table using a custom embedding provider. Useful for tests.
    static func buildTable(
        source: [[String]],
        target: [[String]],
        chapterOffset: Int = 0,
        provider: EmbeddingProvider,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> ParagraphAlignmentTable {
        let total = max(1, source.count)
        var result: [[TargetParagraphRange?]] = []
        result.reserveCapacity(source.count)
        for (cIdx, sourceParas) in source.enumerated() {
            try Task.checkCancellation()
            let targetCIdx = cIdx + chapterOffset
            let targetParas: [String]
            if targetCIdx >= 0 && targetCIdx < target.count {
                targetParas = target[targetCIdx]
            } else {
                targetParas = []
            }
            if sourceParas.isEmpty || targetParas.isEmpty {
                result.append(Array(repeating: nil, count: sourceParas.count))
                progress(Double(cIdx + 1) / Double(total))
                continue
            }
            let sv = try await provider.embedBatch(sourceParas)
            let tv = try await provider.embedBatch(targetParas)
            var sim = Array(repeating: Array(repeating: Float(0), count: targetParas.count),
                            count: sourceParas.count)
            for i in 0..<sourceParas.count {
                for j in 0..<targetParas.count {
                    sim[i][j] = NeedlemanWunsch.cosine(sv[i], tv[j])
                }
            }
            let alignment = NeedlemanWunsch.align(similarity: sim)
            let mapped: [TargetParagraphRange?] = alignment.map { range in
                guard let r = range else { return nil }
                return TargetParagraphRange(start: r.lowerBound, end: r.upperBound)
            }
            result.append(mapped)
            progress(Double(cIdx + 1) / Double(total))
        }
        return ParagraphAlignmentTable(perSourceChapter: result)
    }
}

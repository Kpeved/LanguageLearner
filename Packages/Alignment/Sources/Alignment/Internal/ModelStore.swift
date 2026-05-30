import Foundation
import CoreML
import ZIPFoundation

/// Phases reported while the sentence-encoder model is being made ready for use.
enum ModelPreparePhase: Sendable, Equatable {
    case downloading
    case unzipping
    case compiling
    case ready
}

/// A model that has been downloaded, compiled, and cached on device.
struct PreparedModel: Sendable {
    let compiledModelURL: URL
    let tokenizerDirURL: URL
}

enum ModelStoreError: Error, Sendable, Equatable {
    case downloadFailed(String)
    case unzipFailed(String)
    case compileFailed(String)
    case missingArtifact(String)
}

/// Downloads, compiles, and caches the multilingual sentence-encoder used by
/// `MiniLMEmbeddingProvider`. The first call fetches a zip release asset
/// (`MiniLM.mlpackage` + `tokenizer/`), unzips it, compiles the model with CoreML,
/// and caches the compiled `.mlmodelc` under Application Support. Later calls return
/// the cached URLs immediately. Concurrent callers share one in-flight preparation.
actor ModelStore {

    static let shared = ModelStore()

    /// Release asset zip produced by `tools/convert_minilm_to_coreml.py`.
    /// Bumping the model means bumping this URL and the cache dir version below.
    static let assetURL = URL(string: "https://github.com/Kpeved/LanguageLearner/releases/download/models-v1/MiniLM-coreml.zip")!

    private let fileManager = FileManager.default
    private var cached: PreparedModel?
    private var inFlight: Task<PreparedModel, Error>?

    private var rootDir: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LanguageLearnerModels/MiniLM-v1", isDirectory: true)
    }
    private var compiledModelURL: URL { rootDir.appendingPathComponent("MiniLM.mlmodelc", isDirectory: true) }
    private var tokenizerDirURL: URL { rootDir.appendingPathComponent("tokenizer", isDirectory: true) }

    /// Returns the cached model, preparing (download + compile) it on first use.
    func prepare(progress: @Sendable @escaping (ModelPreparePhase) -> Void = { _ in }) async throws -> PreparedModel {
        if let cached { return cached }
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.doPrepare(progress: progress) }
        inFlight = task
        defer { inFlight = nil }
        let result = try await task.value
        cached = result
        return result
    }

    private func doPrepare(progress: @Sendable @escaping (ModelPreparePhase) -> Void) async throws -> PreparedModel {
        // Fast path: already compiled and cached.
        if fileManager.fileExists(atPath: compiledModelURL.path),
           fileManager.fileExists(atPath: tokenizerDirURL.appendingPathComponent("tokenizer.json").path) {
            progress(.ready)
            return PreparedModel(compiledModelURL: compiledModelURL, tokenizerDirURL: tokenizerDirURL)
        }

        try fileManager.createDirectory(at: rootDir, withIntermediateDirectories: true)

        // Download.
        progress(.downloading)
        NSLog("[Alignment] ModelStore downloading %@", Self.assetURL.absoluteString)
        let zipURL = rootDir.appendingPathComponent("download.zip")
        try? fileManager.removeItem(at: zipURL)
        let (tmp, response) = try await URLSession.shared.download(from: Self.assetURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? fileManager.removeItem(at: tmp)
            throw ModelStoreError.downloadFailed("HTTP \(http.statusCode)")
        }
        try fileManager.moveItem(at: tmp, to: zipURL)

        // Unzip into a staging dir.
        progress(.unzipping)
        let stage = rootDir.appendingPathComponent("stage", isDirectory: true)
        try? fileManager.removeItem(at: stage)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
        do {
            try fileManager.unzipItem(at: zipURL, to: stage)
        } catch {
            throw ModelStoreError.unzipFailed(error.localizedDescription)
        }
        try? fileManager.removeItem(at: zipURL)

        let stagedPackage = stage.appendingPathComponent("MiniLM.mlpackage", isDirectory: true)
        let stagedTokenizer = stage.appendingPathComponent("tokenizer", isDirectory: true)
        guard fileManager.fileExists(atPath: stagedPackage.path) else {
            throw ModelStoreError.missingArtifact("MiniLM.mlpackage")
        }
        guard fileManager.fileExists(atPath: stagedTokenizer.appendingPathComponent("tokenizer.json").path) else {
            throw ModelStoreError.missingArtifact("tokenizer/tokenizer.json")
        }

        // Compile the mlpackage to an mlmodelc.
        progress(.compiling)
        NSLog("[Alignment] ModelStore compiling model")
        let compiledTmp: URL
        do {
            compiledTmp = try await MLModel.compileModel(at: stagedPackage)
        } catch {
            throw ModelStoreError.compileFailed(error.localizedDescription)
        }

        // Move compiled model + tokenizer into their cached homes.
        try? fileManager.removeItem(at: compiledModelURL)
        try fileManager.moveItem(at: compiledTmp, to: compiledModelURL)
        try? fileManager.removeItem(at: tokenizerDirURL)
        try fileManager.moveItem(at: stagedTokenizer, to: tokenizerDirURL)
        try? fileManager.removeItem(at: stage)

        progress(.ready)
        NSLog("[Alignment] ModelStore ready")
        return PreparedModel(compiledModelURL: compiledModelURL, tokenizerDirURL: tokenizerDirURL)
    }
}

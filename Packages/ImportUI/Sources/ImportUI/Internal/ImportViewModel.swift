import Foundation
import Observation
import EPUBKit
import LibraryStore

@MainActor
@Observable
final class ImportViewModel {
    // MARK: - Observed state
    private(set) var phase: ImportPhase = .idle

    // MARK: - Injected dependencies
    private let store: any LibraryStore
    private let parser: any EPUBParser
    private let onComplete: (PairedEntryID) -> Void
    private let onCancel: () -> Void

    // MARK: - Intermediate state
    private var targetURL: URL?
    private var nativeURL: URL?
    private var parsedTarget: EPUBBook?

    // MARK: - Init
    init(
        store: any LibraryStore,
        parser: any EPUBParser,
        onComplete: @escaping (PairedEntryID) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.store = store
        self.parser = parser
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    // MARK: - Phase transitions

    /// Called when the view is ready to start the flow.
    func startFlow() {
        phase = .pickingTarget
    }

    /// Called by `DocumentPickerRepresentable` once the user picks the target EPUB.
    func didPickTarget(url: URL) {
        NSLog("[ImportUI] didPickTarget: %@", url.path)
        targetURL = url
        parseTarget(url: url)
    }

    /// Called by `DocumentPickerRepresentable` once the user picks the native EPUB.
    func didPickNative(url: URL) {
        NSLog("[ImportUI] didPickNative: %@", url.path)
        nativeURL = url
        parseNative(url: url)
    }

    /// Cancels the whole flow and notifies the host.
    func cancel() {
        onCancel()
    }

    /// Resets the state machine back to `.idle` for a retry.
    func retry() {
        targetURL = nil
        nativeURL = nil
        parsedTarget = nil
        phase = .idle
    }

    // MARK: - Private parsing helpers

    private func parseTarget(url: URL) {
        phase = .parsingTarget(progress: 0.05)
        Task {
            do {
                let book = try await parser.parse(url)
                // Signal parse complete before moving on.
                phase = .parsingTarget(progress: 1.0)
                parsedTarget = book
                // Advance to native pick.
                phase = .pickingNative
            } catch {
                phase = .failed(errorMessage(from: error))
            }
        }
    }

    private func parseNative(url: URL) {
        phase = .parsingNative(progress: 0.05)
        Task {
            do {
                guard let targetBook = parsedTarget, let targetSource = targetURL else {
                    phase = .failed("Internal error: target book unavailable.")
                    return
                }
                let nativeBook = try await parser.parse(url)
                phase = .parsingNative(progress: 1.0)
                await writeToStore(target: targetBook, native: nativeBook, targetSource: targetSource, nativeSource: url)
            } catch {
                phase = .failed(errorMessage(from: error))
            }
        }
    }

    private func writeToStore(
        target: EPUBBook,
        native: EPUBBook,
        targetSource: URL,
        nativeSource: URL
    ) async {
        phase = .writingToStore
        do {
            let entryID = try await store.importPair(
                target: target,
                native: native,
                targetSource: targetSource,
                nativeSource: nativeSource
            )
            phase = .done(entryID)
            onComplete(entryID)
        } catch {
            phase = .failed(errorMessage(from: error))
        }
    }

    // MARK: - Error mapping

    private func errorMessage(from error: Error) -> String {
        if let parseError = error as? EPUBParseError {
            switch parseError {
            case .unsupportedEncryption:
                return "This EPUB is DRM-protected and cannot be imported."
            case .notAZipArchive:
                return "The selected file is not a valid EPUB archive."
            case .missingContainerXML:
                return "The EPUB is missing its container manifest."
            case .missingOPF:
                return "The EPUB package descriptor (OPF) could not be found."
            case .malformedSpine:
                return "The EPUB spine is empty or malformed."
            case .ioFailure(let message):
                return "A file error occurred: \(message)"
            }
        }
        return error.localizedDescription
    }
}

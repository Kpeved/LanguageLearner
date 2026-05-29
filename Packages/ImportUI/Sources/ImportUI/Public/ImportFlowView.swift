import SwiftUI
import EPUBKit
import LibraryStore

/// The top-level import flow view. Presents a two-step EPUB file picker (target then
/// native language), shows parse and write progress, and calls back on completion or
/// cancellation.
public struct ImportFlowView: View {
    @State private var viewModel: ImportViewModel

    /// - Parameters:
    ///   - store: The library store that will persist the imported pair.
    ///   - parser: The EPUB parser to use. Defaults to `DefaultEPUBParser()`.
    ///   - onComplete: Called with the new `PairedEntryID` once the import succeeds.
    ///   - onCancel: Called when the user dismisses the flow without completing an import.
    public init(
        store: any LibraryStore,
        parser: any EPUBParser = DefaultEPUBParser(),
        onComplete: @escaping (PairedEntryID) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _viewModel = State(
            initialValue: ImportViewModel(
                store: store,
                parser: parser,
                onComplete: onComplete,
                onCancel: onCancel
            )
        )
    }

    public var body: some View {
        NavigationStack {
            phaseContent
                .navigationTitle("Import Books")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            viewModel.cancel()
                        }
                    }
                }
        }
        .onAppear {
            if case .idle = viewModel.phase {
                viewModel.startFlow()
            }
        }
    }

    // MARK: - Phase rendering

    @ViewBuilder
    private var phaseContent: some View {
        switch viewModel.phase {
        case .idle:
            idleView

        case .pickingTarget:
            pickingView(
                label: "Pick Target-Language EPUB",
                description: "Select the EPUB in the language you are learning.",
                isPickingTarget: true
            )

        case .pickingNative:
            pickingView(
                label: "Pick Native-Language EPUB",
                description: "Select the same book in your native language.",
                isPickingTarget: false
            )

        case .parsingTarget(let progress):
            parsingView(label: "Parsing target-language book...", progress: progress)

        case .parsingNative(let progress):
            parsingView(label: "Parsing native-language book...", progress: progress)

        case .writingToStore:
            savingView

        case .done:
            doneView

        case .failed(let message):
            failureView(message: message)
        }
    }

    // MARK: - Phase sub-views

    private var idleView: some View {
        VStack(spacing: 16) {
            Text("Ready to import a paired book.")
                .foregroundStyle(.secondary)
            Button("Start Import") {
                viewModel.startFlow()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func pickingView(label: String, description: String, isPickingTarget: Bool) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 60))
                .foregroundStyle(.tint)
            Text(label)
                .font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
#if canImport(UIKit)
            DocumentPickerButton(isPickingTarget: isPickingTarget, viewModel: viewModel)
#else
            Text("File picking is only available on iOS.")
                .foregroundStyle(.secondary)
#endif
        }
        .padding()
    }

    private func parsingView(label: String, progress: Double) -> some View {
        VStack(spacing: 20) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .padding(.horizontal)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var savingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Saving to library...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var doneView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            Text("Import complete!")
                .font(.headline)
        }
        .padding()
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.red)
            Text("Import Failed")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Button("Try Again") {
                    viewModel.retry()
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel") {
                    viewModel.cancel()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}

// MARK: - DocumentPickerButton (UIKit-only helper view)

#if canImport(UIKit)
private struct DocumentPickerButton: View {
    let isPickingTarget: Bool
    let viewModel: ImportViewModel

    @State private var isPresenting = false

    var body: some View {
        Button(isPickingTarget ? "Pick Target EPUB" : "Pick Native EPUB") {
            isPresenting = true
        }
        .buttonStyle(.borderedProminent)
        .sheet(isPresented: $isPresenting) {
            DocumentPickerRepresentable(
                onPick: { url in
                    isPresenting = false
                    if isPickingTarget {
                        viewModel.didPickTarget(url: url)
                    } else {
                        viewModel.didPickNative(url: url)
                    }
                },
                onCancel: {
                    isPresenting = false
                    // Do not cancel the whole flow; let the user try again.
                }
            )
        }
    }
}
#endif

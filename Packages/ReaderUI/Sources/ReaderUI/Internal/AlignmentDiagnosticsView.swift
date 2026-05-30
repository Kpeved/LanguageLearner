import SwiftUI
import LibraryStore

/// Read-only sheet explaining how the per-paragraph alignment was computed for the
/// current entry: which phase it reached, the language pair, mapped vs unmapped counts,
/// and any error. Lets the user understand why a tap lands on an approximated paragraph.
struct AlignmentDiagnosticsView: View {

    let diagnostics: AlignmentDiagnostics?
    /// True when tap-to-translate is currently backed by the embedding table.
    let isUsingTable: Bool
    /// 1-based number of the chapter currently open in the reader.
    let currentChapterNumber: Int
    let onAlignChapter: () async -> Void
    let onRefresh: () async -> Void
    let onRecompute: () async -> Void
    let onDismiss: () -> Void

    @State private var isAligningChapter = false
    @State private var isRecomputing = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if let d = diagnostics {
                    detailSection(d)
                    if let message = d.message, !message.isEmpty {
                        messageSection(message, phase: d.phase)
                    }
                }
                explanationSection
                alignChapterSection
                recomputeSection
            }
            .navigationTitle("Alignment")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { await onRefresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                }
            }
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(activePathDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if diagnostics?.phase == .running {
                ProgressView(value: diagnostics?.progress ?? 0)
            }
        }
    }

    private func detailSection(_ d: AlignmentDiagnostics) -> some View {
        Section("Details") {
            row("Languages", "\(displayLang(d.sourceLanguage)) \u{2192} \(displayLang(d.targetLanguage))")
            row("Chapters aligned", "\(d.alignedChapters) / \(d.totalChapters)")
            if d.phase == .completed || d.mappedParagraphs > 0 || d.unmappedParagraphs > 0 {
                row("Paragraphs matched", "\(d.mappedParagraphs)")
                row("Paragraphs unmatched", "\(d.unmappedParagraphs)")
            }
            row("Updated", d.updatedAt.formatted(date: .abbreviated, time: .standard))
        }
    }

    private func messageSection(_ message: String, phase: AlignmentPhase) -> some View {
        Section(phase == .failed ? "Error" : "Note") {
            Text(message)
                .font(.callout)
                .foregroundStyle(phase == .failed ? .red : .secondary)
                .textSelection(.enabled)
        }
    }

    private var explanationSection: some View {
        Section {
            Text("When alignment is unavailable, tapping a paragraph falls back to a proportional estimate, which can land on the wrong paragraph when the two books split text differently.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var alignChapterSection: some View {
        Section {
            Button {
                Task {
                    isAligningChapter = true
                    await onAlignChapter()
                    isAligningChapter = false
                }
            } label: {
                HStack {
                    if isAligningChapter {
                        ProgressView()
                    } else {
                        Image(systemName: "text.aligncenter")
                    }
                    Text(isAligningChapter ? "Aligning chapter \(currentChapterNumber)." : "Align this chapter (\(currentChapterNumber))")
                }
            }
            .disabled(isAligningChapter || isRecomputing)
        } header: {
            Text("Paragraph alignment")
        } footer: {
            Text("Aligns the open chapter against its paired native chapter. Pair chapters first with the Sync button if they do not line up.")
        }
    }

    private var recomputeSection: some View {
        Section {
            Button {
                Task {
                    isRecomputing = true
                    await onRecompute()
                    isRecomputing = false
                }
            } label: {
                HStack {
                    if isRecomputing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(isRecomputing ? "Recomputing." : "Recompute alignment")
                }
            }
            .disabled(isRecomputing || diagnostics?.phase == .running)
        } footer: {
            Text("Rebuilds the alignment for this book without re-importing.")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Presentation helpers

    private var statusTitle: String {
        switch diagnostics?.phase {
        case .none: return "Not computed"
        case .pending: return "Pending"
        case .running: return "Computing alignment"
        case .completed: return "Alignment ready"
        case .failed: return "Alignment failed"
        }
    }

    private var activePathDescription: String {
        isUsingTable
            ? "Taps use embedding-based paragraph alignment."
            : "Taps use proportional approximation."
    }

    private var statusIcon: String {
        switch diagnostics?.phase {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .running, .pending: return "hourglass"
        case .none: return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch diagnostics?.phase {
        case .completed: return isUsingTable ? .green : .orange
        case .failed: return .red
        case .running, .pending: return .blue
        case .none: return .secondary
        }
    }

    private func displayLang(_ tag: String) -> String {
        guard !tag.isEmpty else { return "?" }
        return Locale.current.localizedString(forLanguageCode: tag) ?? tag
    }
}

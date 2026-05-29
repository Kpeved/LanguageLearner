import SwiftUI

/// Side-by-side picker used by the reader to align target and native chapters.
/// - Tap a Target row to jump the reader to that chapter.
/// - Tap a Native row to mark it as paired with the currently-open target chapter.
struct SyncChaptersSheet: View {
    let targetTitles: [String?]
    let nativeTitles: [String?]
    let currentTargetIndex: Int
    let currentOffset: Int
    let onPickNative: (_ nativeIndex: Int) -> Void
    let onPickTarget: (_ targetIndex: Int) -> Void
    let onClear: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                if targetTitles.isEmpty && nativeTitles.isEmpty {
                    ContentUnavailableView(
                        "Chapter titles not available",
                        systemImage: "questionmark.folder",
                        description: Text("This book pair has no chapter index. Re-import the books to enable chapter sync.")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        column(
                            heading: "Target",
                            subheading: "tap to jump",
                            tintColor: .blue,
                            icon: "book",
                            titles: targetTitles,
                            highlightIndex: currentTargetIndex,
                            rowTapAction: onPickTarget
                        )
                        Divider()
                        column(
                            heading: "Native",
                            subheading: "tap to pair",
                            tintColor: .orange,
                            icon: "globe",
                            titles: nativeTitles,
                            highlightIndex: inferredNativeIndex,
                            rowTapAction: onPickNative
                        )
                    }
                }
            }
            .navigationTitle("Sync Chapters")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onCancel() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Reset Offset") { onClear() }
                        .disabled(currentOffset == 0)
                }
            }
        }
    }

    private var inferredNativeIndex: Int {
        let raw = currentTargetIndex + currentOffset
        let upper = max(0, nativeTitles.count - 1)
        return min(max(0, raw), upper)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(headerMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            if currentOffset != 0 {
                Text("Current offset: \(currentOffset >= 0 ? "+" : "")\(currentOffset)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 10)
    }

    private var headerMessage: String {
        let targetTitle = targetTitles.indices.contains(currentTargetIndex)
            ? (targetTitles[currentTargetIndex] ?? "Chapter \(currentTargetIndex + 1)")
            : "Chapter \(currentTargetIndex + 1)"
        return "Currently reading \"\(targetTitle)\". Tap a Native chapter to pair it with this one, or tap a Target chapter to jump there."
    }

    @ViewBuilder
    private func column(
        heading: String,
        subheading: String,
        tintColor: Color,
        icon: String,
        titles: [String?],
        highlightIndex: Int,
        rowTapAction: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column heading
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(tintColor)
                VStack(alignment: .leading, spacing: 0) {
                    Text(heading)
                        .font(.headline)
                    Text(subheading)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tintColor.opacity(0.08))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                            row(
                                index: index,
                                title: title,
                                isHighlighted: index == highlightIndex,
                                tintColor: tintColor,
                                onTap: { rowTapAction(index) }
                            )
                            .id(index)
                            Divider()
                        }
                    }
                }
                .onAppear {
                    proxy.scrollTo(highlightIndex, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func row(index: Int, title: String?, isHighlighted: Bool, tintColor: Color, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, alignment: .trailing)
                Text(title ?? "Untitled")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isHighlighted ? tintColor.opacity(0.22) : Color.clear)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isHighlighted ? tintColor : Color.clear)
                    .frame(width: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

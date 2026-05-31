import SwiftUI
import SwiftData
import UIKit
import LibraryStore
import TTSService
import ReaderUI
import ImportUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Device"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "iphone"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct LibraryRootView: View {
    let store: any LibraryStore
    let tts: any TTSService

    @Query(sort: \PairedEntry.createdAt, order: .reverse)
    private var entries: [PairedEntry]

    @State private var presentingImport = false
    @State private var presentingSettings = false
    @AppStorage("appTheme") private var appTheme: AppTheme = .system

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No paired books yet",
                        systemImage: "books.vertical",
                        description: Text("Tap + to import a target + native EPUB pair.")
                    )
                } else {
                    List {
                        ForEach(entries) { entry in
                            NavigationLink {
                                ReaderView(entryID: entry.id, store: store, tts: tts)
                            } label: {
                                LibraryRow(entry: entry)
                            }
                        }
                        .onDelete(perform: deleteEntries)
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        presentingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        presentingImport = true
                    } label: {
                        Label("New Library Entry", systemImage: "plus")
                    }
                    .accessibilityLabel("New Library Entry")
                }
            }
            .sheet(isPresented: $presentingImport) {
                ImportFlowView(
                    store: store,
                    onComplete: { _ in
                        presentingImport = false
                    },
                    onCancel: {
                        presentingImport = false
                    }
                )
            }
            .sheet(isPresented: $presentingSettings) {
                SettingsView(appTheme: $appTheme)
            }
        }
        .preferredColorScheme(appTheme.colorScheme)
    }

    private func deleteEntries(at offsets: IndexSet) {
        let targets = offsets.map { entries[$0].id }
        Task {
            for id in targets {
                try? await store.deleteEntry(id)
            }
        }
    }
}

private struct LibraryRow: View {
    let entry: PairedEntry

    var body: some View {
        HStack(spacing: 12) {
            cover
                .frame(width: 48, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.targetBook.title)
                    .font(.headline)
                    .lineLimit(2)
                if let author = entry.targetBook.author, !author.isEmpty {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(languagePair)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var cover: some View {
        if let data = entry.targetBook.coverPNG, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.18))
                .overlay {
                    Image(systemName: "book.closed")
                        .foregroundStyle(.secondary)
                }
        }
    }

    private var languagePair: String {
        let target = entry.targetBook.language.isEmpty ? "?" : entry.targetBook.language
        let native = entry.nativeBook.language.isEmpty ? "?" : entry.nativeBook.language
        return "\(target) -> \(native)"
    }
}

struct SettingsView: View {
    @Binding var appTheme: AppTheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appTheme) {
                        ForEach(AppTheme.allCases) { theme in
                            Label(theme.label, systemImage: theme.systemImage)
                                .tag(theme)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

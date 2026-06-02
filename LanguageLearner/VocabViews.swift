import SwiftUI
import VocabKit
import TTSService

// MARK: - Deck

/// Browsable list of saved vocabulary cards with a prominent entry point into review.
struct DeckView: View {
    let vocab: any VocabStore
    let tts: any TTSService

    @Environment(\.dismiss) private var dismiss
    @State private var model: DeckModel
    @State private var searchText = ""
    @State private var presentingReview = false

    init(vocab: any VocabStore, tts: any TTSService) {
        self.vocab = vocab
        self.tts = tts
        self._model = State(initialValue: DeckModel(vocab: vocab))
    }

    private var filtered: [VocabCardSummary] {
        guard !searchText.isEmpty else { return model.cards }
        let q = searchText.lowercased()
        return model.cards.filter {
            $0.surface.lowercased().contains(q)
                || $0.lemma.lowercased().contains(q)
                || $0.translation.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.cards.isEmpty {
                    ContentUnavailableView(
                        "No saved words yet",
                        systemImage: "bookmark",
                        description: Text("Long-press a word while reading, then tap the bookmark to save it here.")
                    )
                } else {
                    List {
                        if model.dueCount > 0 {
                            Section {
                                Button {
                                    presentingReview = true
                                } label: {
                                    Label("Review \(model.dueCount) due", systemImage: "play.circle.fill")
                                        .font(.headline)
                                }
                            }
                        }
                        Section("All words (\(model.cards.count))") {
                            ForEach(filtered) { card in
                                DeckRow(card: card)
                            }
                            .onDelete(perform: delete)
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search words")
                }
            }
            .navigationTitle("Vocabulary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $presentingReview) {
                ReviewView(vocab: vocab, tts: tts, onFinished: { Task { await model.reload() } })
            }
        }
        .task { await model.reload() }
    }

    private func delete(at offsets: IndexSet) {
        let ids = offsets.map { filtered[$0].id }
        Task {
            for id in ids { try? await vocab.deleteCard(id) }
            await model.reload()
        }
    }
}

private struct DeckRow: View {
    let card: VocabCardSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(card.surface).font(.headline)
                if card.surface.lowercased() != card.lemma.lowercased() {
                    Text("(\(card.lemma))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text(card.translation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let sentence = card.latestSighting?.sentence, !sentence.isEmpty {
                Text(sentence)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

@MainActor
@Observable
final class DeckModel {
    private let vocab: any VocabStore
    var cards: [VocabCardSummary] = []
    var dueCount: Int = 0

    init(vocab: any VocabStore) {
        self.vocab = vocab
    }

    func reload() async {
        cards = (try? await vocab.allCards()) ?? []
        dueCount = (try? await vocab.dueCount(asOf: Date())) ?? 0
    }
}

// MARK: - Review

/// Spaced-repetition review session. Shows a cloze front (the source sentence with the
/// word blanked plus a translation hint), reveals the answer, then grades the card.
struct ReviewView: View {
    let vocab: any VocabStore
    let tts: any TTSService
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: ReviewModel

    init(vocab: any VocabStore, tts: any TTSService, onFinished: @escaping () -> Void) {
        self.vocab = vocab
        self.tts = tts
        self.onFinished = onFinished
        self._model = State(initialValue: ReviewModel(vocab: vocab, tts: tts))
    }

    var body: some View {
        Group {
            if let card = model.current {
                cardBody(card)
            } else {
                ContentUnavailableView {
                    Label("All caught up", systemImage: "checkmark.circle.fill")
                } description: {
                    Text(model.reviewed == 0 ? "Nothing is due right now." : "You reviewed \(model.reviewed) card\(model.reviewed == 1 ? "" : "s").")
                }
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.start()
            onFinishedIfDone()
        }
    }

    @ViewBuilder
    private func cardBody(_ card: VocabCardSummary) -> some View {
        VStack(spacing: 24) {
            ProgressView(value: model.progress)
                .padding(.horizontal)

            Spacer(minLength: 0)

            VStack(spacing: 16) {
                clozeText(card)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if let context = card.latestSighting?.nativeContext, !context.isEmpty {
                    VStack(spacing: 4) {
                        Text("From the translation")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        Text(context)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }

                Text(card.translation)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)

                Button {
                    model.speak(card)
                } label: {
                    Label("Listen", systemImage: "speaker.wave.2.fill")
                }
                .buttonStyle(.bordered)

                if model.revealed {
                    Divider().padding(.horizontal, 60)
                    VStack(spacing: 6) {
                        Text(card.surface)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.tint)
                        if card.surface.lowercased() != card.lemma.lowercased() {
                            Text("dictionary form: \(card.lemma)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            if model.revealed {
                gradeButtons
            } else {
                Button {
                    model.revealed = true
                } label: {
                    Text("Reveal")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
            }
        }
        .padding(.vertical)
    }

    private var gradeButtons: some View {
        HStack(spacing: 12) {
            gradeButton("Again", .red) { grade(.again) }
            gradeButton("Good", .blue) { grade(.good) }
            gradeButton("Easy", .green) { grade(.easy) }
        }
        .padding(.horizontal)
    }

    private func gradeButton(_ title: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
    }

    private func grade(_ grade: ReviewGrade) {
        Task {
            await model.grade(grade)
            onFinishedIfDone()
        }
    }

    private func onFinishedIfDone() {
        if model.current == nil { onFinished() }
    }

    /// Renders the sentence with the saved word replaced by a blank.
    private func clozeText(_ card: VocabCardSummary) -> Text {
        guard let sighting = card.latestSighting, !sighting.sentence.isEmpty else {
            return Text("____")
        }
        let ns = sighting.sentence as NSString
        let location = sighting.wordLocation
        let length = sighting.wordLength
        guard location >= 0, length > 0, location + length <= ns.length else {
            return Text(sighting.sentence)
        }
        let before = ns.substring(to: location)
        let after = ns.substring(from: location + length)
        return Text(before) + Text(" ____ ").bold().foregroundColor(.accentColor) + Text(after)
    }
}

@MainActor
@Observable
final class ReviewModel {
    private let vocab: any VocabStore
    private let tts: any TTSService

    private var queue: [VocabCardSummary] = []
    private var index = 0
    var revealed = false
    var reviewed = 0

    init(vocab: any VocabStore, tts: any TTSService) {
        self.vocab = vocab
        self.tts = tts
    }

    var current: VocabCardSummary? {
        index < queue.count ? queue[index] : nil
    }

    var progress: Double {
        guard !queue.isEmpty else { return 1 }
        return Double(index) / Double(queue.count)
    }

    func start() async {
        // Snapshot the due queue once so grading (which pushes due dates out) doesn't
        // mutate the list mid-session.
        queue = (try? await vocab.dueCards(asOf: Date())) ?? []
        index = 0
        revealed = false
        reviewed = 0
    }

    func grade(_ grade: ReviewGrade) async {
        guard let card = current else { return }
        try? await vocab.grade(card.id, grade, at: Date())
        reviewed += 1
        index += 1
        revealed = false
    }

    func speak(_ card: VocabCardSummary) {
        let text = card.latestSighting?.sentence ?? card.surface
        guard !text.isEmpty, let voice = tts.bestVoice(forLanguage: card.targetLanguage) else { return }
        let tts = self.tts
        Task { await tts.speak(text, voice: voice, rate: 0.5) }
    }
}

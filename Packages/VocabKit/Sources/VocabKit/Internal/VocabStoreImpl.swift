import Foundation
import SwiftData

/// `@MainActor`-isolated SwiftData implementation of `VocabStore`, matching the
/// `LibraryStoreImpl` pattern so all `ModelContext` access stays on the main actor.
@MainActor
final class VocabStoreImpl {

    private let modelContext: ModelContext

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    nonisolated init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Save

    func saveOrAppend(
        lemma: String,
        surface: String,
        translation: String,
        partOfSpeech: String?,
        targetLanguage: String,
        nativeLanguage: String,
        sighting: Sighting
    ) throws -> UUID {
        let key = lemma.lowercased()
        if let existing = try fetchCard(lemma: key, targetLanguage: targetLanguage) {
            var sightings = (try? Self.decoder.decode([Sighting].self, from: existing.sightingsData)) ?? []
            sightings.append(sighting)
            existing.sightingsData = (try? Self.encoder.encode(sightings)) ?? existing.sightingsData
            // Surface to the latest encounter; refresh translation if a non-empty one arrived.
            existing.surface = surface
            if !translation.isEmpty { existing.translation = translation }
            if existing.partOfSpeech == nil { existing.partOfSpeech = partOfSpeech }
            try modelContext.save()
            return existing.id
        }

        let data = (try? Self.encoder.encode([sighting])) ?? Data()
        let now = Date()
        let card = VocabCard(
            lemma: key,
            surface: surface,
            translation: translation,
            targetLanguage: targetLanguage,
            nativeLanguage: nativeLanguage,
            partOfSpeech: partOfSpeech,
            createdAt: now,
            sightingsData: data,
            dueDate: now
        )
        modelContext.insert(card)
        try modelContext.save()
        return card.id
    }

    // MARK: - Read

    func allCards() throws -> [VocabCardSummary] {
        let descriptor = FetchDescriptor<VocabCard>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map(Self.summary)
    }

    func dueCards(asOf date: Date) throws -> [VocabCardSummary] {
        var descriptor = FetchDescriptor<VocabCard>(
            predicate: #Predicate { $0.dueDate <= date },
            sortBy: [SortDescriptor(\.dueDate, order: .forward)]
        )
        descriptor.fetchLimit = nil
        return try modelContext.fetch(descriptor).map(Self.summary)
    }

    func dueCount(asOf date: Date) throws -> Int {
        let descriptor = FetchDescriptor<VocabCard>(
            predicate: #Predicate { $0.dueDate <= date }
        )
        return try modelContext.fetchCount(descriptor)
    }

    // MARK: - Grade

    func grade(_ id: UUID, _ grade: ReviewGrade, at date: Date) throws {
        guard let card = try fetchCard(id: id) else { throw VocabError.cardNotFound(id) }
        let outcome = SRSScheduler.next(
            easeFactor: card.easeFactor,
            intervalDays: card.intervalDays,
            repetitions: card.repetitions,
            lapses: card.lapses,
            grade: grade,
            now: date
        )
        card.easeFactor = outcome.easeFactor
        card.intervalDays = outcome.intervalDays
        card.repetitions = outcome.repetitions
        card.lapses = outcome.lapses
        card.dueDate = outcome.dueDate
        card.lastReviewedAt = date
        try modelContext.save()
    }

    // MARK: - Delete

    func deleteCard(_ id: UUID) throws {
        guard let card = try fetchCard(id: id) else { return }
        modelContext.delete(card)
        try modelContext.save()
    }

    // MARK: - Helpers

    private func fetchCard(id: UUID) throws -> VocabCard? {
        let descriptor = FetchDescriptor<VocabCard>(predicate: #Predicate { $0.id == id })
        return try modelContext.fetch(descriptor).first
    }

    private func fetchCard(lemma: String, targetLanguage: String) throws -> VocabCard? {
        let descriptor = FetchDescriptor<VocabCard>(
            predicate: #Predicate { $0.lemma == lemma && $0.targetLanguage == targetLanguage }
        )
        return try modelContext.fetch(descriptor).first
    }

    private static func summary(_ card: VocabCard) -> VocabCardSummary {
        let sightings = (try? decoder.decode([Sighting].self, from: card.sightingsData)) ?? []
        return VocabCardSummary(
            id: card.id,
            lemma: card.lemma,
            surface: card.surface,
            translation: card.translation,
            targetLanguage: card.targetLanguage,
            nativeLanguage: card.nativeLanguage,
            dueDate: card.dueDate,
            intervalDays: card.intervalDays,
            createdAt: card.createdAt,
            latestSighting: sightings.last
        )
    }
}

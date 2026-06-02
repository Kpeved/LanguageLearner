import Foundation
import SwiftData

/// Persistence interface for saved vocabulary cards.
///
/// Mirrors the `LibraryStore` shape: a `Sendable` protocol with a `@unchecked Sendable`
/// concrete type that forwards to a `@MainActor` implementation, because SwiftData's
/// `ModelContext` is main-actor bound.
public protocol VocabStore: Sendable {
    /// Saves a new card, or appends a `Sighting` to the existing card with the same
    /// `(lemma, targetLanguage)`. Returns the card's id. Re-encountering a word keeps its
    /// schedule and updates the surface/translation to the latest encounter.
    func saveOrAppend(
        lemma: String,
        surface: String,
        translation: String,
        partOfSpeech: String?,
        targetLanguage: String,
        nativeLanguage: String,
        sighting: Sighting
    ) async throws -> UUID

    /// All cards, newest first.
    func allCards() async throws -> [VocabCardSummary]

    /// Cards due for review at or before `date`, oldest-due first.
    func dueCards(asOf date: Date) async throws -> [VocabCardSummary]

    /// Count of cards due at or before `date`.
    func dueCount(asOf date: Date) async throws -> Int

    /// Applies a review grade, advancing the card's schedule.
    func grade(_ id: UUID, _ grade: ReviewGrade, at date: Date) async throws

    /// Deletes a card.
    func deleteCard(_ id: UUID) async throws
}

public extension VocabStore {
    func dueCards(asOf date: Date = .now) async throws -> [VocabCardSummary] {
        try await dueCards(asOf: date)
    }
    func dueCount(asOf date: Date = .now) async throws -> Int {
        try await dueCount(asOf: date)
    }
    func grade(_ id: UUID, _ grade: ReviewGrade, at date: Date = .now) async throws {
        try await self.grade(id, grade, at: date)
    }
}

/// Production `VocabStore`. Holds only the `@MainActor` implementation reference, so it
/// is safe to capture across actors.
public final class DefaultVocabStore: VocabStore, @unchecked Sendable {
    private let impl: VocabStoreImpl

    public init(modelContext: ModelContext) {
        self.impl = VocabStoreImpl(modelContext: modelContext)
    }

    public func saveOrAppend(
        lemma: String,
        surface: String,
        translation: String,
        partOfSpeech: String?,
        targetLanguage: String,
        nativeLanguage: String,
        sighting: Sighting
    ) async throws -> UUID {
        try await impl.saveOrAppend(
            lemma: lemma,
            surface: surface,
            translation: translation,
            partOfSpeech: partOfSpeech,
            targetLanguage: targetLanguage,
            nativeLanguage: nativeLanguage,
            sighting: sighting
        )
    }

    public func allCards() async throws -> [VocabCardSummary] {
        try await impl.allCards()
    }

    public func dueCards(asOf date: Date) async throws -> [VocabCardSummary] {
        try await impl.dueCards(asOf: date)
    }

    public func dueCount(asOf date: Date) async throws -> Int {
        try await impl.dueCount(asOf: date)
    }

    public func grade(_ id: UUID, _ grade: ReviewGrade, at date: Date) async throws {
        try await impl.grade(id, grade, at: date)
    }

    public func deleteCard(_ id: UUID) async throws {
        try await impl.deleteCard(id)
    }
}

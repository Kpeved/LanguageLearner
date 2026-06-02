import Testing
import Foundation
import SwiftData
@testable import VocabKit

private func makeStore() throws -> DefaultVocabStore {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: VocabCard.self, configurations: config)
    return DefaultVocabStore(modelContext: ModelContext(container))
}

private func sighting(_ sentence: String, word: String) -> Sighting {
    let ns = sentence as NSString
    let range = ns.range(of: word)
    return Sighting(
        sentence: sentence,
        wordLocation: range.location,
        wordLength: range.length,
        bookTitle: "Book",
        chapterIndex: 0,
        date: Date()
    )
}

@Suite("VocabStore")
struct VocabStoreTests {

    @Test @MainActor func saveCreatesOneCard() async throws {
        let store = try makeStore()
        _ = try await store.saveOrAppend(
            lemma: "run", surface: "running", translation: "courir",
            partOfSpeech: "Verb", targetLanguage: "en", nativeLanguage: "fr",
            sighting: sighting("He is running fast.", word: "running")
        )
        let all = try await store.allCards()
        #expect(all.count == 1)
        #expect(all.first?.lemma == "run")
        #expect(all.first?.surface == "running")
    }

    @Test @MainActor func sameLemmaAppendsSightingInsteadOfNewCard() async throws {
        let store = try makeStore()
        _ = try await store.saveOrAppend(
            lemma: "run", surface: "running", translation: "courir",
            partOfSpeech: nil, targetLanguage: "en", nativeLanguage: "fr",
            sighting: sighting("He is running.", word: "running")
        )
        _ = try await store.saveOrAppend(
            lemma: "run", surface: "ran", translation: "courir",
            partOfSpeech: nil, targetLanguage: "en", nativeLanguage: "fr",
            sighting: sighting("She ran home.", word: "ran")
        )
        let all = try await store.allCards()
        #expect(all.count == 1)
        // Surface advances to the latest encounter.
        #expect(all.first?.surface == "ran")
        #expect(all.first?.latestSighting?.sentence == "She ran home.")
    }

    @Test @MainActor func differentTargetLanguageMakesSeparateCard() async throws {
        let store = try makeStore()
        _ = try await store.saveOrAppend(
            lemma: "run", surface: "run", translation: "courir",
            partOfSpeech: nil, targetLanguage: "en", nativeLanguage: "fr",
            sighting: sighting("Run now.", word: "Run")
        )
        _ = try await store.saveOrAppend(
            lemma: "run", surface: "run", translation: "x",
            partOfSpeech: nil, targetLanguage: "de", nativeLanguage: "fr",
            sighting: sighting("Run now.", word: "Run")
        )
        #expect(try await store.allCards().count == 2)
    }

    @Test @MainActor func newCardIsImmediatelyDue() async throws {
        let store = try makeStore()
        _ = try await store.saveOrAppend(
            lemma: "run", surface: "run", translation: "courir",
            partOfSpeech: nil, targetLanguage: "en", nativeLanguage: "fr",
            sighting: sighting("Run.", word: "Run")
        )
        #expect(try await store.dueCount(asOf: Date()) == 1)
    }

    @Test @MainActor func goodGradePushesCardOutOfTodaysQueue() async throws {
        let store = try makeStore()
        let id = try await store.saveOrAppend(
            lemma: "run", surface: "run", translation: "courir",
            partOfSpeech: nil, targetLanguage: "en", nativeLanguage: "fr",
            sighting: sighting("Run.", word: "Run")
        )
        let now = Date()
        try await store.grade(id, .good, at: now)
        #expect(try await store.dueCount(asOf: now) == 0)
        // One day later it is due again.
        let tomorrow = now.addingTimeInterval(86_400 + 60)
        #expect(try await store.dueCount(asOf: tomorrow) == 1)
    }

    @Test @MainActor func deleteRemovesCard() async throws {
        let store = try makeStore()
        let id = try await store.saveOrAppend(
            lemma: "run", surface: "run", translation: "courir",
            partOfSpeech: nil, targetLanguage: "en", nativeLanguage: "fr",
            sighting: sighting("Run.", word: "Run")
        )
        try await store.deleteCard(id)
        #expect(try await store.allCards().isEmpty)
    }
}

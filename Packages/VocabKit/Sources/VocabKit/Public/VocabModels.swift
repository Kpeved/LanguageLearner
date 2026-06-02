import Foundation
import SwiftData

/// A single saved vocabulary item, keyed by its dictionary form (`lemma`).
///
/// Identity is the lemma + target language: re-encountering the same word in a
/// different inflection appends a `Sighting` rather than creating a second card,
/// so coverage stats stay honest. The surface form and the sentence it came from
/// are kept because they are the strongest recall cue (see `Sighting`).
@Model public final class VocabCard {
    @Attribute(.unique) public var id: UUID
    /// Canonical dictionary form used for deduplication and known-word stats.
    public var lemma: String
    /// The most recently encountered inflected form, shown on the card back.
    public var surface: String
    /// Translation of the word/phrase into the native language.
    public var translation: String
    /// BCP-47 code of the learning language.
    public var targetLanguage: String
    /// BCP-47 code of the native language.
    public var nativeLanguage: String
    /// Coarse part of speech from the lemmatizer, if known (noun/verb/...).
    public var partOfSpeech: String?
    public var createdAt: Date

    /// JSON-encoded `[Sighting]`: each place this word was encountered. Embedded
    /// rather than a relationship because we never query across sightings; this
    /// mirrors the `paragraphAlignmentData` blob pattern on `PairedEntry`.
    public var sightingsData: Data

    // MARK: SM-2 lite scheduling state
    public var easeFactor: Double = 2.5
    public var intervalDays: Double = 0
    public var repetitions: Int = 0
    public var lapses: Int = 0
    public var dueDate: Date
    public var lastReviewedAt: Date?

    public init(
        id: UUID = UUID(),
        lemma: String,
        surface: String,
        translation: String,
        targetLanguage: String,
        nativeLanguage: String,
        partOfSpeech: String?,
        createdAt: Date,
        sightingsData: Data,
        easeFactor: Double = 2.5,
        intervalDays: Double = 0,
        repetitions: Int = 0,
        lapses: Int = 0,
        dueDate: Date,
        lastReviewedAt: Date? = nil
    ) {
        self.id = id
        self.lemma = lemma
        self.surface = surface
        self.translation = translation
        self.targetLanguage = targetLanguage
        self.nativeLanguage = nativeLanguage
        self.partOfSpeech = partOfSpeech
        self.createdAt = createdAt
        self.sightingsData = sightingsData
        self.easeFactor = easeFactor
        self.intervalDays = intervalDays
        self.repetitions = repetitions
        self.lapses = lapses
        self.dueDate = dueDate
        self.lastReviewedAt = lastReviewedAt
    }
}

/// One encounter of a word: the sentence it appeared in plus the character range of
/// the surface form within that sentence (used to render the cloze blank).
public struct Sighting: Codable, Sendable, Equatable {
    public var sentence: String
    /// Location of the surface form inside `sentence` (NSString indices).
    public var wordLocation: Int
    /// Length of the surface form inside `sentence` (NSString indices).
    public var wordLength: Int
    /// The matching sentence from the aligned parallel (native) book, taken directly from
    /// the translation. Optional so sightings saved before this existed still decode.
    public var nativeContext: String?
    public var bookTitle: String?
    public var chapterIndex: Int
    public var date: Date

    public init(
        sentence: String,
        wordLocation: Int,
        wordLength: Int,
        nativeContext: String? = nil,
        bookTitle: String?,
        chapterIndex: Int,
        date: Date
    ) {
        self.sentence = sentence
        self.wordLocation = wordLocation
        self.wordLength = wordLength
        self.nativeContext = nativeContext
        self.bookTitle = bookTitle
        self.chapterIndex = chapterIndex
        self.date = date
    }
}

/// A `Sendable` snapshot of a `VocabCard` for the UI layer (which never touches the
/// `@MainActor`-bound `ModelContext`).
public struct VocabCardSummary: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let lemma: String
    public let surface: String
    public let translation: String
    public let targetLanguage: String
    public let nativeLanguage: String
    public let dueDate: Date
    public let intervalDays: Double
    public let createdAt: Date
    /// The most recent sighting, used to render the cloze front. nil only if a card
    /// was somehow saved without context.
    public let latestSighting: Sighting?

    public init(
        id: UUID,
        lemma: String,
        surface: String,
        translation: String,
        targetLanguage: String,
        nativeLanguage: String,
        dueDate: Date,
        intervalDays: Double,
        createdAt: Date,
        latestSighting: Sighting?
    ) {
        self.id = id
        self.lemma = lemma
        self.surface = surface
        self.translation = translation
        self.targetLanguage = targetLanguage
        self.nativeLanguage = nativeLanguage
        self.dueDate = dueDate
        self.intervalDays = intervalDays
        self.createdAt = createdAt
        self.latestSighting = latestSighting
    }
}

/// How well the user recalled a card during review.
public enum ReviewGrade: Sendable, Equatable {
    case again
    case good
    case easy
}

public enum VocabError: Error, Sendable, Equatable {
    case cardNotFound(UUID)
}

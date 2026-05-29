# Dual-Language Parallel Reader - Architecture Design

Spec: `docs/specs/dual-language-reader.md`

## Modules

| Package | Purpose | Depends on |
|---|---|---|
| `EPUBKit` | Parse a reflowable EPUB 2/3 file into an ordered list of chapters of (title, paragraphs). | - |
| `LibraryStore` | SwiftData models, on-disk chapter file I/O, last-read position, paired-book lifecycle. | EPUBKit, Alignment |
| `Alignment` | Pure functions for proportional mapping between two paragraph streams. No I/O. | - |
| `TTSService` | Thin wrapper around `AVSpeechSynthesizer` with voice quality discovery and rate control. | - |
| `ReaderUI` | SwiftUI reading view, sentence tap targeting, translation panel, TTS controls. | LibraryStore, Alignment, TTSService |
| `ImportUI` | SwiftUI file picker, dual-EPUB import flow, parse-and-persist progress. | LibraryStore, EPUBKit |
| `App` (`LanguageLearner/`) | Thin shell: app entry, `ModelContainer`, root navigation. | all packages |

Each package lives at `Packages/<Name>/` with `Sources/<Name>/Public/` and `Sources/<Name>/Internal/`. Tests at `Packages/<Name>/Tests/<Name>Tests/`.

## Public APIs

### EPUBKit

```swift
// Public/EPUBModels.swift
public struct EPUBChapter: Sendable, Equatable {
    public let title: String?
    public let paragraphs: [String]   // plain text, whitespace-collapsed, one entry per <p>
}

public struct EPUBBook: Sendable, Equatable {
    public let title: String
    public let author: String?
    public let language: String       // BCP-47 from <dc:language>, may be ""
    public let coverPNG: Data?        // pre-decoded if a cover was found, else nil
    public let chapters: [EPUBChapter]
}

public enum EPUBParseError: Error, Sendable {
    case notAZipArchive
    case missingContainerXML
    case missingOPF
    case unsupportedEncryption       // surface DRM as a clear error
    case malformedSpine
    case ioFailure(underlying: Error)
}

// Public/EPUBParser.swift
public protocol EPUBParser: Sendable {
    func parse(_ url: URL) async throws -> EPUBBook
}

public struct DefaultEPUBParser: EPUBParser {
    public init()
    public func parse(_ url: URL) async throws -> EPUBBook
}
```

Internals (not exported): `ZIPFoundation` glue, OPF/NAV XML parsers (`XMLParser` delegate), XHTML-to-paragraph stripper, cover extraction.

### Alignment

```swift
// Public/AlignmentModels.swift
public struct ParagraphIndex: Hashable, Sendable {
    public let chapterIndex: Int
    public let paragraphIndex: Int
}

public struct ParagraphRange: Sendable, Equatable {
    public let start: ParagraphIndex   // inclusive
    public let end: ParagraphIndex     // inclusive
}

/// Cumulative character offsets per paragraph, precomputed at import time.
/// `perChapterCumulative[c][p]` = chars before paragraph p of chapter c (within its scope).
public struct AlignmentProfile: Codable, Sendable, Equatable {
    public let perChapterCumulative: [[Int]]   // length == chapters.count; each inner length == paragraphs.count + 1
    public let perChapterTotals: [Int]
    public let bookTotal: Int
    public init(perChapterCumulative: [[Int]], perChapterTotals: [Int], bookTotal: Int)
}

public enum AlignmentPolicy: Sendable, Equatable {
    case chapterAnchored    // when source.chapterCount == target.chapterCount
    case wholeBook          // fallback
}

// Public/AlignmentEngine.swift
public protocol AlignmentEngine: Sendable {
    static func profile(for chapters: [[String]]) -> AlignmentProfile
    static func policy(source: AlignmentProfile, target: AlignmentProfile) -> AlignmentPolicy
    static func mapParagraph(_ p: ParagraphIndex,
                             from source: AlignmentProfile,
                             to target: AlignmentProfile,
                             policy: AlignmentPolicy) -> ParagraphIndex
    static func window(around centre: ParagraphIndex,
                       radius: Int,
                       in target: AlignmentProfile,
                       policy: AlignmentPolicy) -> ParagraphRange
}

public enum DefaultAlignmentEngine: AlignmentEngine {
    // static-method-only namespace
}
```

### LibraryStore

```swift
// Public/LibraryModels.swift  (SwiftData @Model classes are declared here, see Data Model)

public typealias PairedEntryID = UUID

public struct ChapterRef: Sendable, Equatable, Hashable {
    public let bookID: UUID
    public let chapterIndex: Int
}

public struct LastReadPosition: Codable, Sendable, Equatable {
    public let chapterIndex: Int
    public let paragraphIndex: Int
    public let scrollFractionWithinParagraph: Double   // 0...1
}

public struct PairedEntrySummary: Sendable, Identifiable, Equatable {
    public let id: PairedEntryID
    public let title: String
    public let author: String?
    public let coverPNG: Data?
    public let targetLanguage: String
    public let nativeLanguage: String
    public let createdAt: Date
}

public enum LibraryError: Error, Sendable {
    case bookNotFound(UUID)
    case chapterNotFound(ChapterRef)
    case storageFull
    case ioFailure(underlying: Error)
}

// Public/LibraryStore.swift
public protocol LibraryStore: Sendable {
    func importPair(target: EPUBBook,
                    native: EPUBBook,
                    targetSource: URL,
                    nativeSource: URL) async throws -> PairedEntryID

    func allEntries() async throws -> [PairedEntrySummary]
    func deleteEntry(_ id: PairedEntryID) async throws

    func bookIDs(forEntry id: PairedEntryID) async throws -> (target: UUID, native: UUID)
    func loadChapter(_ ref: ChapterRef) async throws -> EPUBChapter
    func alignmentProfile(forBook id: UUID) async throws -> AlignmentProfile

    func lastReadPosition(forEntry id: PairedEntryID) async throws -> LastReadPosition?
    func updateLastReadPosition(_ pos: LastReadPosition, forEntry id: PairedEntryID) async throws
}

public final class DefaultLibraryStore: LibraryStore {
    public init(modelContext: ModelContext, fileManager: FileManager = .default)
}
```

### TTSService

```swift
// Public/TTSModels.swift
public struct TTSVoice: Sendable, Equatable {
    public let identifier: String      // AVSpeechSynthesisVoice.identifier
    public let language: String        // BCP-47
    public let quality: Quality
    public enum Quality: Sendable, Equatable { case `default`, enhanced, premium }
}

public enum TTSEvent: Sendable, Equatable {
    case started
    case finished
    case cancelled
    case failed(reason: String)
}

// Public/TTSService.swift
public protocol TTSService: AnyObject, Sendable {
    func bestVoice(forLanguage tag: String) -> TTSVoice?
    func hasHighQualityVoice(forLanguage tag: String) -> Bool
    func speak(_ text: String, voice: TTSVoice, rate: Double) async
    func stop()
    var events: AsyncStream<TTSEvent> { get }
}

public final class DefaultTTSService: TTSService {
    public init()
}
```

### ReaderUI

```swift
// Public/ReaderView.swift
public struct ReaderView: View {
    public init(entryID: PairedEntryID,
                store: any LibraryStore,
                tts: any TTSService)
    public var body: some View
}

// Public/ReaderSettings.swift
public struct ReaderSettings: Codable, Sendable, Equatable {
    public var fontPointSize: Double      // 14...28
    public var ttsRate: Double            // 0.3...1.0
    public static let `default`: ReaderSettings
}
```

Internals (not exported):
- `ChapterScrollView`, `SentenceTapOverlay` (uses `NLTokenizer(.sentence)` per paragraph, lazy)
- `TranslationPanel` (3-paragraph window, `<` / `>` expand by ±1)
- `ReaderViewModel` (`@Observable`, owns currentChapter, tappedParagraph, panelRange, ttsState)
- `SentenceLocator` (maps tap location -> (paragraphIndex, sentence range))

### ImportUI

```swift
// Public/ImportFlowView.swift
public struct ImportFlowView: View {
    public init(store: any LibraryStore,
                parser: any EPUBParser = DefaultEPUBParser(),
                onComplete: @escaping (PairedEntryID) -> Void,
                onCancel: @escaping () -> Void)
    public var body: some View
}

// Public/ImportProgress.swift
public enum ImportPhase: Sendable, Equatable {
    case idle
    case pickingTarget, pickingNative
    case parsingTarget(progress: Double)
    case parsingNative(progress: Double)
    case writingToStore
    case done(PairedEntryID)
    case failed(String)
}
```

Internals: `DocumentPickerRepresentable` (UIDocumentPickerViewController, two-step pick), `ImportViewModel` (`@Observable`).

### App shell

`LanguageLearner/LanguageLearner/LanguageLearnerApp.swift` is rewritten to:
- Construct `ModelContainer` with the `LibraryStore` schema (replaces `Item`).
- Instantiate `DefaultLibraryStore`, `DefaultTTSService`.
- Root view: `LibraryRootView` (lives in the app, not a package) that lists `PairedEntrySummary` rows, presents `ImportFlowView` modally on "+", pushes `ReaderView(entryID:)` on row tap.

`Item.swift` and the SwiftData boilerplate are deleted.

## Data model

### SwiftData `@Model` classes (declared in LibraryStore Public)

```swift
@Model public final class PairedEntry {
    @Attribute(.unique) public var id: UUID
    public var createdAt: Date
    public var targetBook: Book           // relationship, cascade delete
    public var nativeBook: Book
    public var lastReadChapterIndex: Int
    public var lastReadParagraphIndex: Int
    public var lastReadScrollFraction: Double
}

@Model public final class Book {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var author: String?
    public var language: String
    public var coverPNG: Data?
    public var chapterTitles: [String?]
    public var paragraphCounts: [Int]     // per chapter; enough to drive alignment lookup without loading chapter text
    public var alignmentProfileData: Data // PropertyListEncoder-encoded AlignmentProfile (binary plist)
    public var storageDirName: String     // relative folder under App Support
}
```

### On-disk layout (App Support)

```
<AppSupport>/Library/
  <bookUUID>/
    chapter-0000.json   // {"title": "...", "paragraphs": ["...", "..."]}
    chapter-0001.json
    ...
    cover.png           // optional
```

- Chapter JSON written once at import, read on demand by `loadChapter`, cached in an LRU keyed by `ChapterRef`.
- Source EPUBs are not retained; we own the extracted normalised text.
- No iCloud, no shared container.

### Single source of truth

- Library list + last-read position: SwiftData.
- Chapter text: filesystem JSON, addressed by `Book.storageDirName + chapter-NNNN.json`.
- Alignment profile: stored inline on `Book` as `Data` (binary plist).
- Reader ephemeral state (scroll, tap): in-memory `@Observable` view model.

## Data flow

### Import flow (US-1)

1. App `LibraryRootView` -> "+" -> presents `ImportFlowView`.
2. `ImportViewModel` -> two-step `DocumentPickerRepresentable` (target then native EPUB).
3. `DefaultEPUBParser.parse(url)` runs on a detached task per file.
4. `LibraryStore.importPair(target:native:targetSource:nativeSource:)`:
   - Allocates UUIDs, creates `<AppSupport>/Library/<uuid>/` directories.
   - Serialises each chapter to `chapter-NNNN.json`.
   - Computes `AlignmentProfile` for each book via `DefaultAlignmentEngine.profile(for:)`.
   - Inserts `Book` (x2) and `PairedEntry` rows; saves.
5. Phase: `done(entryID)` -> dismiss sheet; library list refreshes via SwiftData `@Query`.

### Tap-to-translate flow (US-3, US-4) - must stay under 100ms

Pre-conditions (paid at chapter-load time, not at tap time):
- Both books' `AlignmentProfile`s decoded into memory when reader opens.
- Current target chapter paragraphs in memory.
- `[paragraphIndex: [NSRange]]` sentence index built lazily per paragraph as it scrolls into view.

At tap:
1. SwiftUI gesture in `SentenceTapOverlay` -> `(paragraphIndex, sentenceRange)` (O(1) lookup over pre-tokenised paragraph).
2. View model sets `tappedParagraph = ParagraphIndex(chapter, paragraph)`.
3. `DefaultAlignmentEngine.mapParagraph(...)` -> centre on native side (O(log n) binary search over cumulative chars).
4. `DefaultAlignmentEngine.window(around: centre, radius: 1, ...)` -> 3-paragraph range.
5. `store.loadChapter(nativeRef)`: cached hit returns instantly; cold path absorbed by adjacent-chapter prefetch (see Risks).
6. Panel slides up (animation off the critical latency path).
7. In parallel, `TTSService.speak(sentenceText, voice: bestVoice(forLanguage: target.language), rate: settings.ttsRate)` fires.

Panel `<` / `>` mutate `radius` and re-call `window(...)`, never re-map.

### Persistence flow (US-5)

- Reader `onChange(scrollPosition)` -> 300ms debounce -> `store.updateLastReadPosition(...)`.
- App start: SwiftData `@Query<PairedEntry>` populates library. Opening an entry reads `lastReadPosition`, seeds initial scroll.

### TTS flow

- `DefaultTTSService` owns an `AVSpeechSynthesizer` + delegate adapter pushing into `AsyncStream<TTSEvent>`.
- ReaderUI subscribes to `tts.events` for indicators.
- Missing enhanced/premium voice: one-shot alert with `App-Prefs:` deep-link.

## Risks

- **Tap-latency cliff on chapter boundaries.** Cold native-chapter JSON decode can blow the 100ms budget. Mitigation: prefetch adjacent native chapters when reader crosses a chapter midpoint; LRU sized for at least 3 chapters per book.
- **Sentence segmentation cost on long paragraphs.** Eager whole-chapter tokenisation stutters scroll; doing it at tap time blows latency. Mitigation: per-paragraph lazy index, computed on scroll idle when the paragraph enters the viewport.
- **EPUB-in-the-wild fragility.** Custom thin parser will hit malformed OPF, non-XHTML content docs, oddly-nested spines. Mitigation: ship a small corpus of real EPUB fixtures in `EPUBKitTests`; fail loudly via typed `EPUBParseError` rather than producing empty chapters.
- **AlignmentProfile size and decode cost.** A 200-chapter book with 100 paragraphs/chapter is ~20k Ints. JSON encoding would be wasteful. Mitigation: `PropertyListEncoder` (binary plist) or packed `Data` of Int32 deltas - decision deferred to LibraryStore coder.
- **Premium voice availability is user-side and out of our control.** AC-5 says deep-link to Settings. Simulator often has no enhanced voices, which would break validator runs against a real `AVSpeechSynthesizer`. Mitigation: TTSService tests use a mockable seam; do not call live synthesiser in unit tests.

## Notes for coders

- `LibraryStore` depends on both `EPUBKit` (for `EPUBBook`/`EPUBChapter` types) and `Alignment` (for `AlignmentProfile`). Declare both in its `Package.swift`.
- `ReaderUI` depends on `LibraryStore`, `Alignment`, and `TTSService`.
- `ImportUI` depends on `LibraryStore` and `EPUBKit`.
- Public types each package needs from others MUST be imported via the public re-export from that package's umbrella; do not duplicate type definitions across packages.
- Where a `Sendable` view model touches SwiftUI on the main actor, isolate via `@MainActor` rather than weakening `Sendable`.

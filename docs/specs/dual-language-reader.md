# Dual-Language Parallel Reader

## Goal
A completely offline iOS app (iOS 17+, SwiftUI) that lets a user read an EPUB in their target language while peeking at proportionally-mapped context from the same book in their native language. Zero network at runtime. Zero API costs. Sub-100ms tap-to-translate latency.

Learning happens through *context*, not 1:1 translation. Mapping is fuzzy/proportional by design.

## User stories

### US-1: Import a paired book
As a learner, I tap "New Library Entry", pick two local EPUBs (target + native of the same work), and the app processes them in the background. When done, the paired entry appears in my library with cover + title from the target-language book.

### US-2: Clean reading
As a reader, I open a paired entry and see only target-language text. The view feels like a standard e-reader: adjustable font size, comfortable margins, vertical scroll, no chrome competing with the page.

### US-3: Fuzzy tap-to-translate
As a reader, I tap a sentence I don't understand. Within 100ms the sentence is highlighted and a bottom panel slides up showing ~3 paragraphs of native-language text from the proportionally-mapped location. I read for context, swipe the panel down, and continue.

### US-4: Hear the sentence
When the panel opens, the tapped sentence is spoken aloud in a high-quality, native-sounding voice. A rate slider (0.3x to 1.0x) inside the panel lets me slow it down. A replay button repeats playback.

### US-5: Resume where I left off
When I close and reopen a book, I land back at the same scroll position. The library remembers all paired entries across app restarts.

## Out of scope
- Cloud sync, accounts, analytics, telemetry
- Fixed-layout EPUBs (reflowable EPUB 2/3 only)
- Inline images, embedded fonts, complex CSS rendering in chapter view
- Runtime LLM calls / sentence-level ML alignment
- Word-level dictionary lookup
- DRM-protected EPUBs (Adobe ADEPT, FairPlay, etc.)
- Audiobook, PDF, MOBI/AZW formats
- iPad-specific layout (universal app, but tuned for iPhone first)

## Acceptance criteria

- **AC-1 Import**: User can pick two EPUB files in one flow; on success a paired library entry appears with the target book's title and metadata.
- **AC-2 Reading**: Reading view scrolls smoothly at 60fps on iPhone 12 or newer; font size adjustable via a toolbar control; only target-language text visible during reading.
- **AC-3 Tap latency**: Tapping any sentence highlights it and presents the translation panel within 100ms with no spinner.
- **AC-4 Proportional mapping**: When chapter counts match, mapping is chapter-anchored proportional within the chapter. When they differ, mapping falls back to whole-book proportional. The native panel always shows ~3 paragraphs centred on the mapped position with `<` / `>` to expand by one paragraph at a time.
- **AC-5 TTS**: Tapping a sentence triggers TTS playback of that exact sentence using `AVSpeechSynthesizer` with an enhanced or premium voice when installed; rate slider mapped to AVSpeechUtterance.rate; if no enhanced voice is installed, a one-time prompt deep-links to Settings.
- **AC-6 Offline**: With airplane mode on, import, library, reading, tap-to-translate, and TTS all work.
- **AC-7 Persistence**: After force-quit and relaunch, library is intact and the last-read scroll offset for each book is restored.
- **AC-8 Tests**: Each feature Swift Package has unit tests covering its public API. Alignment math has property tests. EPUB parsing has fixtures.

## Non-goals for v1, candidates for later
- Bookmarks, highlights, notes
- Multiple paired entries per work (e.g. one target + multiple natives)
- Word-tap (only sentence-tap in v1)
- Reading statistics / streaks
- Themes beyond system light/dark

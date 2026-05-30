# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# Project: LanguageLearner (Dual-Language Parallel Reader)

Offline iOS 17+ SwiftUI app. Reads two EPUBs of the same book in parallel: a target-language EPUB (what the user is learning) and a native-language EPUB (the same book translated). Tapping a target paragraph opens a bottom panel showing the proportionally-mapped native chapter, centred on the matched paragraph, with TTS playback of the tapped paragraph.

- **Spec**: `docs/specs/dual-language-reader.md`
- **Architecture doc**: `docs/design/dual-language-reader.md`
- **GitHub**: https://github.com/Kpeved/LanguageLearner
- **Template lineage**: forked from `_claude-template`. See `README.md` for the `/build` multi-agent pipeline rationale.

## Tech stack

- Swift 5.9+, SwiftUI, iOS 17.0+ deployment target, Xcode 26.x
- SwiftData for persistence (`PairedEntry`, `Book` are `@Model` classes in `LibraryStore`)
- AVSpeechSynthesizer for TTS (in `TTSService`)
- `NaturalLanguage.NLContextualEmbedding` for cross-lingual paragraph alignment (in `Alignment`)
- ZIPFoundation (external SPM package) for EPUB ZIP reading
- swift-testing (`@Test`, `#expect`, `@Suite`) for all package tests
- Persistent storage: `<AppSupport>/LanguageLearnerLibrary/<bookUUID>/chapter-NNNN.json` plus `default.store` SwiftData DB

## Module map

| Package | Public API | Internals | Depends on |
|---|---|---|---|
| `Packages/EPUBKit` | `DefaultEPUBParser.parse(url) -> EPUBBook` (chapters with `[title, paragraphs]`) | `ContainerXMLParser`, `OPFParser`, `NCXParser`, `XHTMLStripper`, `EPUBParserCore`. ZIP via ZIPFoundation. | ZIPFoundation |
| `Packages/Alignment` | `DefaultAlignmentEngine` (chapter-anchored / wholeBook proportional, with `offset`), `DefaultParagraphAligner.buildTable` (embedding + Needleman-Wunsch, supports 1:N/N:1), `ParagraphAlignmentTable`, `TargetParagraphRange` | `NeedlemanWunsch.align`, `NLContextualEmbeddingProvider` (mean-pooled subword vectors), `BinarySearch.bucket` | NaturalLanguage |
| `Packages/LibraryStore` | `LibraryStore` protocol + `DefaultLibraryStore`. SwiftData `@Model`s `PairedEntry`, `Book`. `LastReadPosition`, `PairedEntrySummary`, `ChapterRef`. Computes paragraph alignment in background task at import. | `LibraryStoreImpl` (`@MainActor`), `ChapterLRU`, `ChapterDTO`. Chapters stored as JSON on disk; alignment profile + paragraph alignment table as binary plist on the SwiftData rows. | EPUBKit, Alignment |
| `Packages/TTSService` | `TTSService` protocol + `DefaultTTSService`. `TTSVoice` (default/enhanced/premium), `TTSEvent` async stream. | `DefaultTTSServiceImpl` (`@MainActor`), `SynthesizerDelegateAdapter`, `VoiceHelpers`, `AudioSessionConfigurator` | AVFoundation |
| `Packages/ReaderUI` | `ReaderView(entryID:store:tts:)`, `ReaderSettings` | `ReaderViewModel` (`@MainActor @Observable`), `ChapterScrollView`, `SentenceTapOverlay` (paragraph-tap), `TranslationPanel` (full native chapter, swipe-to-dismiss, highlights range), `SyncChaptersSheet` (target=blue tap-to-jump, native=orange tap-to-pair) | LibraryStore, Alignment, TTSService |
| `Packages/ImportUI` | `ImportFlowView`, `ImportPhase` enum | `ImportViewModel`, `DocumentPickerRepresentable` (UIDocumentPicker for `.epub`) | LibraryStore, EPUBKit |

**App target** `LanguageLearner.xcodeproj` (thin shell):
- `LanguageLearner/LanguageLearnerApp.swift`: builds `ModelContainer` for `[PairedEntry.self, Book.self]`, instantiates `DefaultLibraryStore` + `DefaultTTSService`.
- `LanguageLearner/ContentView.swift`: `LibraryRootView` — SwiftData `@Query<PairedEntry>` list, `+` toolbar -> `ImportFlowView` sheet, `NavigationLink` -> `ReaderView`. Swipe-to-delete.
- Bundle ID: `Blabla.LanguageLearner`. Simulator data path: `~/Library/Developer/CoreSimulator/Devices/<DEVICE_UDID>/data/Containers/Data/Application/<APP_UUID>/Library/Application Support/`.

## Build / run / test

**Critical**: `xcode-select` on this machine points at `CommandLineTools`, not Xcode. `swift build`/`swift test` from the terminal need `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` prefixed.

```bash
# Build a single package + run its tests
cd "Packages/<Name>"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

**Run a single test (swift-testing)**:
```bash
cd "Packages/<Name>"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter "<SuiteName>/<testName>"
# e.g. swift test --filter "ParagraphAlignerTests/buildTableProducesMonotonicRanges"
```
For the app target, use `RunSomeTests` from `xcode-tools` MCP with the test identifier.

**Prefer the `xcode-tools` MCP server** for the full-app build — much faster than running xcodebuild from the shell:
- `BuildProject` builds and reports errors.
- `GetBuildLog` retrieves the last build log if you need to grep it.
- `RunAllTests` / `RunSomeTests` run the app's tests on the simulator.

**Install + launch on simulator** (used after `BuildProject` returns success):
```bash
APP="$HOME/Library/Developer/Xcode/DerivedData/LanguageLearner-gcoeflojnbladlfxarwxedcgzvmb/Build/Products/Debug-iphonesimulator/LanguageLearner.app"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl terminate booted Blabla.LanguageLearner 2>/dev/null
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl install booted "$APP"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl launch booted Blabla.LanguageLearner
```

**Iteration loop**: edit code -> `BuildProject` -> reinstall+launch (snippet above) -> ask user to test. Do NOT call `xcodebuild` from Bash unless you need a switch the MCP tool doesn't expose; it is much slower.

**Run app under Xcode debugger** to see `NSLog` output: in Xcode press **Cmd+R**, open Debug Area with **Cmd+Shift+Y**, filter the console by `[EPUBParser]` or `[App]`.

## Critical conventions (encode in code; do not re-discover)

These are real bugs we fixed once. Failing to follow them brings them back.

### SwiftUI layout
- **NEVER wrap content in `GeometryReader`** when it is the only child of a layout container — `GeometryReader` greedily fills the available space and breaks `LazyVStack` / `ScrollView` sizing. Use the **`.background(GeometryReader { ... })`** pattern when you only need to read the size into a `@State`.
- `.bottomBar` toolbar placement is iOS-only. When a package targets iOS+macOS, conditionalise via a helper `var bottomBarPlacement: ToolbarItemPlacement { #if os(iOS) return .bottomBar #else return .automatic #endif }`.
- `.navigationBarTitleDisplayMode(.inline)` is also iOS-only — wrap in `#if os(iOS)`.
- `ContentUnavailableView` is preferred for empty states.

### EPUB parsing
- **EPUB OPF hrefs are URI-percent-encoded** (`%20` etc.) but ZIP central directory entries are stored literally. `EPUBParserCore.tryReadEntry` and `readEntry` already try both forms — preserve that. New ZIP lookup helpers must do the same.
- **NCX `<navPoint>` can be nested arbitrarily**. `NCXParser` uses a stack and commits at every level via `storeTitle(href:title:)`. Do not regress to a depth-counter that only commits at depth 1; nested navPoints get lost otherwise.
- `storeTitle` stores every title under **four keys**: raw href, percent-decoded href, bare filename, decoded bare filename. The spine-side title lookup in `EPUBParserCore.parseChapters` tries all of them. Keep both sides in sync.
- Reject 0-chapter parses early; otherwise SwiftData persists garbage entries that hang the reader. Currently surfaced via the reader's error screen.

### Reading + alignment
- **Tap-to-sentence using pixel math is unreliable** and was removed. `SentenceTapOverlay` is now paragraph-tap only (whole paragraph highlights + becomes the TTS utterance). Do not reintroduce sub-paragraph pixel hit-testing without a real UITextView/TextKit2 path.
- `DefaultAlignmentEngine.mapParagraph` in **`.chapterAnchored`** mode uses **paragraph-index proportional**, not character-proportional. Character-proportional produced visible "skipping" when paragraph lengths differ between languages.
- **Whole-book mode keeps the character-proportional path** (better signal when chapter counts differ).
- `chapterOffset != 0` forces `.chapterAnchored` policy regardless of chapter-count match — see `ReaderViewModel.computePolicy`.
- **Paragraph alignment table** (`DefaultParagraphAligner.buildTable`) overrides proportional mapping when available. It computes one `TargetParagraphRange` per source paragraph using `NLContextualEmbedding` (multilingual within a script group: Latin/Cyrillic/CJK/Indic/Arabic/Thai) and a Needleman-Wunsch DP that allows 1:N and N:1. Runs as a detached background task during `importPair` so import returns immediately. `ReaderViewModel` polls every 2s for up to 2 min after load.
- `TranslationPanel.highlightRange != nil` -> highlight every paragraph in the range with the accent background. `highlightRange == nil` -> highlight only `centreParagraphIndex`.

### Persistence + storage
- SwiftData additive migration works for **new properties with default values**: just add `var newField: Type = default`. Tested for `targetChapterOffset` and `paragraphAlignmentData`. Old user data migrates lightweight.
- **Storage layout**: `<AppSupport>/LanguageLearnerLibrary/<bookUUID>/chapter-NNNN.json` + optional `cover.png`. Alignment profile stored as binary plist in `Book.alignmentProfileData`. Per-pair paragraph alignment table stored as binary plist in `PairedEntry.paragraphAlignmentData`.
- `Book.storageDirName` == `Book.id.uuidString` at import time. Do not derive paths any other way.
- Imports that crash mid-`writeChapters` can leave **orphan directories**. Currently surfaced by the reader showing a friendly `ioFailure` with the missing path. If you add cleanup-on-launch, scan `LibraryStore.allEntries()` and verify chapter-0000.json exists for each Book.

### Logging
- `os.Logger` (`Logger`) output does **not** reliably reach the Xcode debug console in this Xcode/iOS combo. **Use `NSLog`** for any diagnostic that needs to be visible during interactive debugging. `EPUBParserCore` has an `epubLog(...)` helper that fires both `Logger.notice` (for Console.app/`log stream`) and `NSLog` (for Xcode Debug Area). Reuse that pattern in other packages.
- `#if DEBUG` does not always propagate from the host app target into SPM packages. Don't gate dev-only logging behind `#if DEBUG` inside packages.
- No `print()` left in committed code. No `TODO:` markers. No em dashes (only short `-`).

### Concurrency
- All SwiftData access goes through `LibraryStoreImpl` which is `@MainActor`. The outer `DefaultLibraryStore` is `@unchecked Sendable` because it only forwards to the actor-isolated impl.
- Background work (paragraph alignment) uses `Task.detached(priority: .utility)`. Persistence of results goes back through `await store.persistAlignment(...)` which hops to main actor.
- `DefaultTTSService` follows the same pattern.
- Long-running polling in view models: capture `let id = entryID; let storeRef = store` before the Task to avoid main-actor capture issues.

### Project file
- **Do not edit `LanguageLearner.xcodeproj/project.pbxproj` while Xcode is open** — it will crash Xcode. If you need to add/remove/move project items, use the `xcode-tools` MCP commands (`XcodeMV`, `XcodeRM`, etc.) or ask the user to do it in the Xcode UI. Adding SPM dependencies in particular MUST be done via Xcode's Package Dependencies sheet.
- The app target uses a `PBXFileSystemSynchronizedRootGroup`. Adding/removing files in `LanguageLearner/LanguageLearner/` is just a filesystem operation — Xcode picks them up automatically.

### Tests
- Use `@Test`/`@Suite`/`#expect` from swift-testing, not XCTest.
- Inject fakes for `LibraryStore`, `TTSService`, `EPUBParser`, `EmbeddingProvider` — see `ReaderUITests` and `AlignmentTests` for patterns.
- `EPUBKitTests` builds a minimal valid EPUB inline via ZIPFoundation (`buildMinimalEPUB` helper) — copy that pattern for new fixtures.
- New tests must mark fakes as `@unchecked Sendable` when they conform to `Sendable` protocols.
- When extending `LibraryStore` protocol, update **both** fakes (`Packages/ReaderUI/Tests/.../ReaderUITests.swift` and `Packages/ImportUI/Tests/.../ImportUITests.swift`) or builds break.
- Run `swift test` for each package after changes; the validator agent also runs the iOS scheme tests.
- App-target tests (`LanguageLearnerTests`, `LanguageLearnerUITests`) run via `RunAllTests` / `RunSomeTests` on the simulator. They use XCTest, not swift-testing — only the SPM packages are swift-testing.

### Style
- Naming: PascalCase types, camelCase members.
- Indent: 4 spaces.
- No force unwraps in production code; tests can use them sparingly.
- Prefer `let` over `var`.
- No Combine; use async/await.
- One module = one Swift Package. Coders work in their assigned package only. Public types each package needs from others MUST be imported via that package; do not duplicate type definitions.
- Only short dashes (`-`), never em dashes (`—`).

## Pipeline / orchestration

`.claude/commands/build.md` defines the multi-agent `/build` pipeline (spec -> designer -> coders in parallel worktrees -> validator -> reviewer). The agents are:
- `designer` (opus) — produces `docs/design/<slug>.md`.
- `coder` (sonnet) — implements one package per invocation, in an isolated git worktree.
- `validator` (haiku) — builds and runs tests on iOS simulator.
- `reviewer` (sonnet) — reviews the merged diff.

Cost posture: cheapest model that can do the job. Subagents have isolated contexts so their raw file reads don't enter the main session.

## Author preferences
- Plan before implementing; ask 1-3 sharp clarifying questions when ambiguous, then propose an approach.
- Exploratory questions get 2-3 sentence responses with tradeoffs, not implementations.
- Terse responses; the user reads the diff.

## One-time setup
```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer   # fix CLI swift
brew install xcbeautify                                            # readable build logs
```
Target simulator: iPhone 17 Pro (or whatever is booted). Current device UDID on this machine: `CF8D86FF-EF8C-4933-AB78-30190E7EDD7D`.

# Project: <app-name>

Generic Claude Code iOS app template. Replace `<app-name>` when instantiating.

## Stack
- Swift 5.9+, SwiftUI, iOS 17+
- Modular via Swift Packages under `Packages/` (one package per feature/module)
- Main app target (`App/`) is a thin shell that wires modules together
- Tests: XCTest, one test target per package

## Layout
- `App/` - main iOS app target (.xcodeproj/.xcworkspace lives here)
- `Packages/<Name>/` - one Swift Package per module
- `docs/specs/<feature>.md` - frozen feature requirements (input to designer)
- `docs/design/<feature>.md` - architecture output from designer
- `.claude/` - orchestration agents, commands, skills

## Conventions
- One module = one Swift Package. Coders work in their assigned package only, never cross-edit.
- Public API of a module lives in `Packages/<Name>/Sources/<Name>/Public/`. Internals are not visible to other modules.
- Prefer protocols over concrete types at module boundaries.
- Tests live in `Packages/<Name>/Tests/<Name>Tests/`.

## Cost posture (cheap-first)
- Default to the cheapest model that can do the job. Haiku for cheap/repeat tasks, Sonnet for code, Opus only for hard design or debugging.
- Prefer subagents with isolated contexts for any exploration, so raw file reads stay out of the main session.
- For ad-hoc work outside `/build`, still apply this preference unless told otherwise.

## Author preferences
- Plan before implementing; ask 1-3 sharp clarifying questions if the request is ambiguous, then propose an approach.
- Use only short dashes (`-`), never em dashes (`—`).

## Workflow
Use `/build "feature description"` to kick off the pipeline. It runs:
1. Main Claude turns the request into a spec at `docs/specs/<slug>.md` (you approve).
2. `designer` agent (opus) produces architecture and module boundaries.
3. `coder` agents (sonnet) run in parallel git worktrees, one per module.
4. `validator` agent (haiku) builds and runs tests on iOS simulator.
5. `reviewer` agent (sonnet) reviews the merged diff.

## Setup notes (one-time per machine)
- Point xcode-select at Xcode (not Command Line Tools):
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
- Install xcbeautify for readable build output: `brew install xcbeautify`
- Target simulator: "iPhone 15" unless otherwise specified.

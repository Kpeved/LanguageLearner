# Claude Code iOS Template

Template for AI-orchestrated iOS app development. Multi-agent pipeline, parallel where possible, cheap-first model tiers.

## Starting a new project

```bash
cp -R "~/Xcode projects/_claude-template" "~/Xcode projects/MyNewApp"
cd "~/Xcode projects/MyNewApp"
git init && git add -A && git commit -m "init from template"
# Edit CLAUDE.md to set the app name
# Open Xcode -> create App.xcodeproj inside App/
# Launch Claude Code from this directory: claude
```

## Workflow

Inside Claude Code, type:

```
/build "your feature description"
```

Pipeline stages:
1. **Spec** - main Claude writes `docs/specs/<slug>.md` (you approve)
2. **Design** - `designer` agent (opus) writes `docs/design/<slug>.md`
3. **Implement** - `coder` agents (sonnet) run in parallel worktrees, one per module
4. **Validate** - `validator` agent (haiku) builds + tests
5. **Review** - `reviewer` agent (sonnet) reviews the diff

## Cost posture (cheap-first)

| Agent | Model | Cost notes |
|---|---|---|
| designer | opus | One call per feature |
| coder | sonnet | Parallel but each has isolated context |
| validator | haiku | Cheap, may run multiple times |
| reviewer | sonnet | One pass at the end |

Change tiers by editing `model:` in each `.claude/agents/*.md` frontmatter.

## Token-saving levers
- Subagents have isolated context. Their raw file reads do not enter your main session.
- `docs/specs/` and `docs/design/` are designed to be short - they are the cache-friendly handoff between stages.
- Cap retries at 2 per feature. The orchestrator stops and asks if it would go beyond.

## One-time machine setup
```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
brew install xcbeautify
```

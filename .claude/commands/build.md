---
description: Orchestrate the full design -> code -> validate -> review pipeline for a new feature.
argument-hint: "<feature description>"
---

You are the orchestrator. The user's feature request is: $ARGUMENTS

Run the pipeline below. Spawn subagents in parallel where indicated using a single message with multiple Agent tool calls. Keep your own messages to the user terse (one line per stage transition).

# Stage 1: Spec
1. Turn $ARGUMENTS into a concise spec at `docs/specs/<slug>.md` using a kebab-case slug.
2. Spec sections: `## Goal`, `## User stories`, `## Out of scope`, `## Acceptance criteria`.
3. If the request is genuinely ambiguous, ask the user 1-3 sharp clarifying questions. Otherwise proceed.
4. Show the spec path to the user and get a thumbs-up before continuing.

# Stage 2: Design (single agent, opus)
1. Invoke `designer` agent with the spec path.
2. The designer writes `docs/design/<slug>.md`.
3. Show the user the module breakdown (Modules section only). Get a thumbs-up before coding.

# Stage 3: Implementation (parallel, sonnet, worktrees)
1. For each module listed in the design, spawn a `coder` agent.
2. CRITICAL: spawn them in parallel - one message with N Agent tool calls.
3. Each `coder` invocation must use `isolation: "worktree"` so they don't conflict.
4. Pass each: target module name, design doc path, spec path.
5. Wait for all to finish before proceeding.

# Stage 4: Merge
1. For each worktree the coders used, review what changed and merge back into the main checkout.
2. Module boundaries should prevent conflicts. If conflicts occur, stop and ask the user.

# Stage 5: Validate (haiku)
1. Invoke `validator` agent.
2. If `Status: FAIL`: re-invoke the relevant `coder` agent with the failure report inlined as input.
3. Cap retries at 2 across the whole pipeline. If still failing, stop and surface the failure to the user.

# Stage 6: Review (sonnet)
1. Invoke `reviewer` agent.
2. Relay verdict to the user. If FIX, list the findings and ask whether to address now or defer.

# Hard rules
- You orchestrate. You do not write or edit code yourself in this pipeline.
- Cost discipline: if any stage is about to loop more than twice, stop and ask.
- After each stage, give the user a single-line status update.

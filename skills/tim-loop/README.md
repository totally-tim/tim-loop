# Tim Loop — Automated Build-Verify-Review System

An automated development loop for Claude Code that takes a feature spec, builds it with TDD, verifies independently, publishes a PR, and reviews it — repeating until the reviewer passes or max cycles are exhausted.

## What It Does

```
You write a spec  -->  Worktree created  -->  3 agents work in a loop  -->  PR ready for review
```

**The loop:**
1. **BUILD** — Builder agent implements the spec using strict TDD
2. **VERIFY** — Independent verifier runs typecheck, lint, tests, build, e2e, plan adherence
3. **FIX** — If verify fails, builder fixes and re-verifies (up to 5 retries)
4. **PUBLISH** — Code committed, pushed, PR created/updated
5. **REVIEW** — Reviewer reads PR diff via GitHub CLI, checks against spec
6. If review fails, findings go back to builder for the next cycle (up to 3 cycles)

**Three agents, each with a single job:**
- **Builder** — writes code and tests (TDD), commits
- **Verifier** — runs all checks independently, can't edit code
- **Reviewer** — reviews PR diff only via `gh` CLI, can't touch local files

The orchestrator (your session) coordinates but never reads code or runs tests — keeping its context window clean enough to survive the full loop.

## Installation

### 1. Copy the skill files

```bash
# Copy both skill directories
cp -r /path/to/source/.claude/skills/tim-loop ~/.claude/skills/tim-loop
cp -r /path/to/source/.claude/skills/tim-spec ~/.claude/skills/tim-spec

# Copy the command wrappers
cp /path/to/source/.claude/commands/tim-loop.md ~/.claude/commands/tim-loop.md
cp /path/to/source/.claude/commands/tim-spec.md ~/.claude/commands/tim-spec.md
```

Or if cloning from a shared location:

```bash
mkdir -p ~/.claude/skills ~/.claude/commands

# From Tim's machine or a shared repo
rsync -av tim@host:~/.claude/skills/tim-loop/ ~/.claude/skills/tim-loop/
rsync -av tim@host:~/.claude/skills/tim-spec/ ~/.claude/skills/tim-spec/
rsync -av tim@host:~/.claude/commands/tim-loop.md ~/.claude/commands/tim-loop.md
rsync -av tim@host:~/.claude/commands/tim-spec.md ~/.claude/commands/tim-spec.md
```

### 2. Verify installation

Start a new Claude Code session and check that both skills appear:

```
/tim-spec    # should show in autocomplete
/tim-loop    # should show in autocomplete
```

### 3. Prerequisites

These should already be available if you use Claude Code with superpowers:

- **superpowers** plugin installed (provides TDD, code-review, worktree, and other skills)
- **playwright-cli** skill at `~/.claude/skills/playwright-cli/` (for browser verification)
- **`gh` CLI** authenticated (`gh auth status`) — needed for PR creation and review
- **Context7 MCP** configured — agents use this to verify library APIs

## File Structure

```
~/.claude/skills/
├── tim-loop/
│   ├── SKILL.md           # Orchestrator skill (the loop logic)
│   ├── tim-builder.md     # Builder agent prompt + reference
│   ├── tim-verifier.md    # Verifier agent prompt + reference
│   ├── tim-reviewer.md    # Reviewer agent prompt + reference
│   └── tim-verify.md      # 3-tier verification strategy
│   └── README.md          # This file
├── tim-spec/
│   └── SKILL.md           # Spec generation skill

~/.claude/commands/
├── tim-loop.md            # /tim-loop command
└── tim-spec.md            # /tim-spec command
```

## Usage

### Generate a spec

```
/tim-spec "add webhook retry logic with exponential backoff"
```

This walks you through brainstorming the feature, then generates a structured spec at `docs/specs/YYYY-MM-DD-<feature>.md`.

### Run the loop

```
/tim-loop docs/specs/2026-02-28-webhook-retries.md
```

This creates a worktree, spawns the team, and runs the build-verify-review loop automatically. You'll see progress updates like:

```
Cycle 1/3: Build complete. Starting verify...
Cycle 1/3: Verify FAIL (attempt 2/5, FIXABLE). Builder fixing...
Cycle 1/3: Verify PASS. Publishing PR...
Cycle 1/3: Review PASS. PR #47 ready for human review.
```

### Writing specs manually

If you prefer to write the spec yourself instead of using `/tim-spec`, follow this format:

```markdown
# Feature: <name>

## Goal
One sentence.

## Requirements
- [ ] Requirement 1
- [ ] Requirement 2

## Architecture
How it fits into the codebase.

## Acceptance Criteria
- When X, then Y
- API returns Z

## Verification (optional)
- Run `specific-command` and expect X
- Skip Playwright (no frontend changes)

## Out of Scope
- What this does NOT include
```

The only required sections are **Goal**, **Requirements**, and **Acceptance Criteria**.

## Configuration

Hardcoded defaults (edit `~/.claude/skills/tim-loop/SKILL.md` to change):

| Setting | Default |
|---------|---------|
| Outer cycles (build-review) | 3 |
| Inner retries (verify-fix) | 5 |
| TDD enforcement | Strict |
| Worktree isolation | Always |

## How It Stays Lean

The orchestrator follows a "thin coordinator" pattern — it only tracks cycle numbers, verdicts, and prognoses. All code reading, test running, and diff analysis happens in the agents. This keeps the main context window clean enough to survive the full 3-cycle loop without compaction.

Agent prompts use an "Iron Laws + Progressive Disclosure" pattern: 5 critical rules in the spawn prompt (reliably followed), with detailed process guidance in reference files that agents read on their first turn.

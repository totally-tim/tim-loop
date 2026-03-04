# Tim Loop — Automated Build-Verify-Review System

An automated development loop for Claude Code that takes a feature spec, builds it with TDD using parallel builders, verifies independently, publishes a PR, and reviews it — repeating until the reviewer passes or max cycles are exhausted.

## What It Does

```
You write a spec  -->  Worktree created  -->  Architect partitions work  -->  N builders work in parallel  -->  PR ready for review
```

**The loop:**
1. **BASELINE** — Verifier records pre-existing failures before building starts
2. **ARCHITECT** — Architect analyzes the codebase, writes shared contracts, and partitions work into N non-overlapping file scopes
3. **BUILD** — N builders work in parallel, each implementing their partition with strict TDD
4. **VERIFY** — Independent verifier runs checks against combined output, compares against baseline
5. **FIX** — If verify fails, failures are routed to the owning builder by file path. Per-builder stagnation detection
6. **PUBLISH** — Code committed, pushed, PR created/updated with priority checklist from all partitions
7. **REVIEW** — Reviewer checks PR diff against spec with priority-aware coverage tracking
8. If review fails, all agents are shut down and fresh agents are spawned with the reviewer's findings for the next cycle

**Four agent roles:**
- **Architect** — explores codebase, creates implementation contract with shared types and partitions, shuts down after planning
- **Builder(s)** — N parallel builders, each scoped to their own files, implementing with TDD
- **Verifier** — runs all checks independently, can't edit code, reports structured failure_keys
- **Reviewer** — reviews PR diff via `gh` CLI, can request screenshots from verifier

The orchestrator coordinates via a shared task list (`Ctrl+T` to see progress) — it never reads code or runs tests.

## Key Features (v3 — Builder Swarm)

- **Parallel builders** — architect partitions work across N builders with non-overlapping file scopes. Each builder gets a focused context window.
- **Architect agent** — dedicated agent explores the codebase, writes shared types/interfaces to disk, and creates an implementation contract before builders start.
- **File-scoped routing** — verification failures are routed to the owning builder by file path. Builders only fix issues in their partition.
- **Per-builder stagnation** — stagnation detection is per-builder. A stagnant builder can be isolated while others continue.
- **Backward compatible** — when the architect produces 1 partition, falls back to single-builder behavior with no scope restrictions.
- **Task-driven coordination** — agents use TaskCreate/TaskUpdate instead of message-passing. Progress visible in real time via `Ctrl+T`.
- **Baseline verification** — pre-existing failures are recorded before building, preventing false negatives.
- **Priority-based requirements** — `[P0]`/`[P1]`/`[P2]` tags determine build order and review strictness.
- **Incremental verification** — on retry, previously-failed checks run first before the full suite.
- **Configurable loop** — spec can override `max_outer_cycles`, `max_inner_retries`, `builder_count`, `max_builders`, and more.
- **Agent refresh between cycles** — all agents are shut down and re-spawned with fresh context windows between outer cycles. Prevents context bloat from accumulated fix attempts. Verifier discovery (test runners, commands) is carried forward so fresh verifiers skip re-discovery.
- **Abort and resume** — on abort, per-partition state is saved to `.tim-loop-resume.json`. Resume spawns builders only for incomplete partitions.
- **Visual review** — reviewer can request screenshots from the verifier for UI changes.

## Installation

```bash
git clone https://github.com/totally-tim/tim-loop.git
cd tim-loop
./install.sh
```

Or manually:

```bash
mkdir -p ~/.claude/skills ~/.claude/commands
cp -r skills/tim-loop ~/.claude/skills/
cp -r skills/tim-spec ~/.claude/skills/
cp commands/tim-loop.md ~/.claude/commands/
cp commands/tim-spec.md ~/.claude/commands/
```

Start a new Claude Code session — `/tim-spec` and `/tim-loop` will appear in autocomplete.

### Prerequisites

- **superpowers** plugin installed (provides TDD, code-review, worktree, and other skills)
- **playwright-cli** skill at `~/.claude/skills/playwright-cli/` (for browser verification)
- **`gh` CLI** authenticated (`gh auth status`) — needed for PR creation and review
- **Context7 MCP** configured — agents use this to verify library APIs

## File Structure

```
~/.claude/skills/
├── tim-loop/
│   ├── SKILL.md           # Orchestrator skill (the loop logic)
│   ├── tim-architect.md   # Architect agent prompt + reference (new)
│   ├── tim-builder.md     # Builder agent prompt + reference
│   ├── tim-verifier.md    # Verifier agent prompt + reference
│   ├── tim-reviewer.md    # Reviewer agent prompt + reference
│   ├── tim-verify.md      # 3-tier verification strategy
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
/tim-spec add webhook retry logic with exponential backoff
```

This walks you through brainstorming, explores the codebase for architecture context, then generates a structured spec at `docs/specs/YYYY-MM-DD-<feature>.md` with prioritized requirements, test strategy, and risk assessment.

### Run the loop

```
/tim-loop docs/specs/2026-02-28-webhook-retries.md
```

Progress updates show in your terminal and the task list (`Ctrl+T`):

```
Architect approved. Spawning 3 builders...
Cycle 1/3: Build complete (3/3 builders done). Starting verify...
Cycle 1/3: Verify FAIL (attempt 2/5, FIXABLE). Routing fixes to 2 builder(s)...
Cycle 1/3: Verify PASS. Publishing PR...
Cycle 1/3: Review FAIL (1 blocking). Refreshing agents for cycle 2...
Cycle 1/3: Agents refreshed (3 builders, verifier, reviewer). Starting cycle 2...
Cycle 2/3: Build complete (3/3 builders done). Starting verify...
Cycle 2/3: Verify PASS. Publishing PR...
Cycle 2/3: Review PASS. PR #47 ready for human review.
```

### Resume after abort

If the loop aborts, it saves state for later:

```
/tim-loop --resume /path/to/worktree/.tim-loop-resume.json
```

### Writing specs manually

If you prefer to write the spec yourself instead of using `/tim-spec`:

```markdown
# Feature: <name>

## Goal
One sentence.

## Requirements
- [ ] [P0] Critical requirement
- [ ] [P1] Important requirement
- [ ] [P2] Nice-to-have requirement

## Architecture
How it fits into the codebase. Specific file paths and patterns.

## Acceptance Criteria
- When X, then Y
- API returns Z

## Test Strategy
- Unit tests for: [modules]
- Mocks: [external services]

## Risk Assessment
- Blast radius: greenfield
- Risk level: low

## Verification (optional)
- Run `specific-command` and expect X
- Skip Playwright (no frontend changes)

## Out of Scope
- What this does NOT include
```

Required sections: **Goal**, **Requirements** (with priority tags), and **Acceptance Criteria**.

## Configuration

Defaults are overridable per-spec via the `## Loop Config` section:

| Setting | Default | Spec Override |
|---------|---------|---------------|
| Outer cycles | 3 | `max_outer_cycles: N` |
| Inner retries | 5 | `max_inner_retries: N` |
| Plan approval (cycle 1) | true | `require_plan_approval: false` |
| Baseline verification | true | `skip_baseline: true` |
| Builder count | auto | `builder_count: N` or `auto` |
| Max builders | 5 | `max_builders: N` |
| TDD enforcement | Strict | Not configurable |
| Worktree isolation | Always | Not configurable |

## How It Stays Lean

The orchestrator follows a "thin coordinator" pattern — it creates tasks, reads task metadata (verdicts, failure_keys, prognoses), and makes decisions. All code reading, test running, and diff analysis happens in the agents.

Agent prompts use an "Iron Laws + Progressive Disclosure" pattern: 5-6 critical rules in the spawn prompt (reliably followed), with detailed process guidance in reference files that agents read on their first turn.

Task-driven coordination means the orchestrator doesn't need to parse agent messages for verdicts — structured metadata on completed tasks provides clean, reliable signals for loop decisions.

The architect agent produces a partition plan that splits work by file ownership — two builders never edit the same file, eliminating merge conflicts. Failures route back to the owning builder by file path in the failure key.

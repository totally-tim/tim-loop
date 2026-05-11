# Tim Loop — Automated Build-Verify-Review System

An automated development loop for Claude Code that takes a feature spec, builds it with TDD using parallel builders, verifies independently, publishes a PR, and reviews it — repeating until the reviewer passes or max cycles are exhausted.

## What It Does

```
You write a spec  -->  Worktree created  -->  Architect partitions work  -->  N builders work in parallel  -->  PR ready for review
```

**The loop:**
1. **SPEC PRE-FLIGHT** — Orchestrator validates verify command, guards, and file references on the clean tree before any agent spawns. Hard-aborts if the spec is broken.
2. **BASELINE** — Verifier records pre-existing failures and runs the verify command for sanity (hard-abort if metric is wonky).
3. **ARCHITECT** — Architect analyzes the codebase + past run lessons, runs a framework pre-flight via Context7 against its own contract (catches edge-runtime gotchas, missing augmentations), then partitions work into N non-overlapping file scopes. Contract is mechanically linted for P0 coverage and stub-shape parity.
4. **CONTRACT NEGOTIATION (conditional)** — only runs when triggers fire (Open Questions affecting a partition, OR HIGH-complexity partition using novel libraries). Default off-by-trigger.
5. **BUILD** — N builders work in parallel, each implementing their partition with strict TDD. Builder runs a Done Self-Check (spec-phrase grep, stub-shape parity, compiler-trap audit) before reporting complete.
6. **INTEGRATE** — Reviewer merges builder branches (Stage A: per-merge guards), applies contract-declared post-merge handoffs (Stage B), then runs POST-HANDOFF-GUARD (Stage C) to catch stub-vs-real-impl drift. Monotonic-progress check on re-attempts.
7. **VERIFY + AUDIT (parallel, PRE-publish)** — Verifier runs Phase 1+2+3; Auditor performs deep source-read in parallel. Combined verdict gates publish. Cross-agent triangulation catches when grep-based evidence was fooled by stubs.
8. **PUBLISH (only if VERIFY+AUDIT pass)** — Push (force-with-lease for re-publishes), PR created/updated with priority checklist and compliance report.
9. **REVIEW (post-publish, CI + code quality only)** — Reviewer waits for CI, checks code quality. Audit already happened pre-publish.
10. If review fails, agents refresh with findings for the next cycle. On success, write lessons artifact for cumulative learning.

**Five agent roles:**
- **Architect** — explores codebase, creates implementation contract with shared types and partitions, shuts down after planning
- **Builder(s)** — N parallel builders, each scoped to their own files, implementing with TDD
- **Verifier** — runs all checks independently, can't edit code, reports structured failure_keys
- **Reviewer** — checks CI status and code quality via `gh` CLI
- **Auditor** — deep spec completeness review by reading actual source files, classifying implementations as REAL/STUB/MISSING and tests as THOROUGH/SHALLOW/MISSING, with per-requirement confidence scoring

The orchestrator coordinates via a shared task list (`Ctrl+T` to see progress) — it never reads code or runs tests.

## Key Features (v4 — Pre-Publish Audit + Token Reduction)

- **Shared context files** — spec/contract/strategy written once to `.tim-loop/context/`; agents reference via path instead of embedding. ~100-150K token savings per cycle on multi-builder runs.
- **Durable phase artifacts** — every phase writes a JSON to `.tim-loop/state/` (baseline.json, integrate-N.json, verify-N.json, audit-N.json, review-N.json). Survives task-ID drift, enables clean resume.
- **Conditional contract negotiation** — defaults to `if_needed` (negotiate only when Open Questions affect a partition or HIGH-complexity partition uses novel libraries). Avoids ~80K tokens of theater on well-specified work.
- **POST-HANDOFF-GUARD** — separate guard run after sed/path-rewrite handoffs to catch stub-vs-real-impl drift that per-merge guards miss.
- **Monotonic-progress re-integration** — no fixed cap. Continue while progress is strict (fewer failure_keys OR changed category). Stop only on stagnation.
- **Pre-publish audit** — auditor runs in parallel with verifier BEFORE publish. PR only goes up if both pass. Eliminates force-push cycles caused by post-publish BLOCKING findings.
- **Spec pre-flight** — orchestrator validates verify command, guards, and file references on clean tree before any agent spawn. Hard-aborts if metric is broken (was advisory, now a gate).
- **Architect framework pre-flight** — Context7 against the contract itself, not just builder code. Catches Auth.js edge-split, Web Crypto, trustHost-style gotchas at design time.
- **Lessons-learned artifact** — every terminal cycle writes `~/.claude/skills/tim-loop/lessons/{date}-{feature}.md`. Architect greps these on first turn for cumulative framework patterns.
- **Parallel builders** — architect partitions work across N builders with non-overlapping file scopes. Each builder gets a focused context window.
- **Architect agent** — dedicated agent explores the codebase, writes shared types/interfaces to disk, and creates an implementation contract with structured P0 coverage matrix and stub-shape parity declarations.
- **Deep spec audit** — auditor reads actual source files (not just grep) to classify implementations as REAL/STUB/MISSING and tests as THOROUGH/SHALLOW/MISSING, with per-requirement confidence scoring.
- **Cross-agent triangulation** — orchestrator compares the verifier's grep-based evidence with the auditor's source-reading assessment. Disagreements (verifier says IMPLEMENTED, auditor says STUB) become high-priority findings.
- **Contract usage verification** — auditor verifies that the architect's shared types/interfaces are actually imported by consuming partitions.
- **Entry-point reachability tracing** — auditor traces new features from the app's entry point through routing and navigation to catch orphaned components that pass tests but are invisible to users.
- **PR compliance report** — auditor produces a human-readable spec compliance table posted to the PR description with per-requirement evidence.
- **File-scoped routing** — verification failures are routed to the owning builder by file path. Builders only fix issues in their partition.
- **Per-builder stagnation** — stagnation detection is per-builder. A stagnant builder can be isolated while others continue.
- **Backward compatible** — when the architect produces 1 partition, falls back to single-builder behavior with no scope restrictions.
- **Task-driven coordination** — agents use TaskCreate/TaskUpdate instead of message-passing. Progress visible in real time via `Ctrl+T`.
- **Baseline verification** — pre-existing failures are recorded before building, preventing false negatives.
- **Priority-based requirements** — `[P0]`/`[P1]`/`[P2]` tags determine build order and review strictness.
- **Configurable loop** — spec can override `max_outer_cycles`, `max_inner_retries`, `builder_count`, `max_builders`, and more.
- **Agent refresh between cycles** — all agents are shut down and re-spawned with fresh context windows between outer cycles. Prevents context bloat from accumulated fix attempts. Verifier discovery (test runners, commands) is carried forward so fresh verifiers skip re-discovery.
- **Abort and resume** — on abort, per-partition state (including auditor findings) is saved to `.tim-loop-resume.json`. Resume spawns builders only for incomplete partitions.
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
- **Browser verification** (at least one): `mcp__claude-in-chrome__*` (preferred, native MCP) or **playwright-cli** skill at `~/.claude/skills/playwright-cli/`
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
│   ├── tim-auditor.md     # Auditor agent prompt + reference
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
Cycle 1/3: Reviewing PR #47 (reviewer: CI+quality, auditor: deep spec audit)...
Cycle 1/3: Reviewer PASS. Auditor found 1 P0 stub. Refreshing agents for cycle 2...
Cycle 2/3: Build complete (3/3 builders done). Starting verify...
Cycle 2/3: Verify PASS. Publishing PR...
Cycle 2/3: Review PASS (CI: 4/4 green, audit: 8 HIGH / 0 MEDIUM confidence). PR #47 ready for human review.
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

# Tim Loop

An automated build-verify-review development loop for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Takes a feature spec, partitions the work across parallel builders in an isolated worktree, verifies independently, publishes a PR, and reviews it — repeating until the reviewer passes or max cycles are exhausted.

```
/tim-spec add webhook retry logic  -->  brainstorm + structured spec
/tim-loop docs/specs/2026-02-28-webhook-retries.md  -->  automated loop --> PR ready
```

## How It Works

```
SETUP: Spec --> Worktree --> Architect partitions work --> N builders spawned --> Baseline verification

THE LOOP (up to 3 cycles):

  1. BUILD        N builders work in parallel, each implementing their partition with TDD
  2. VERIFY       Independent verifier runs checks against baseline
  2b. FIX         If verify fails, failures routed to owning builder by file path
                  Per-builder stagnation detection: 3 identical failures = isolate or abort
  3. PUBLISH      Commit, push, create/update PR with priority checklist
  4. REVIEW       Reviewer checks PR diff against spec by priority

  PASS --> Done. PR ready for human review.
  FAIL --> Findings routed to relevant builders, next cycle starts.
  ABORT --> Per-partition state saved for resume.
```

**Four agent roles:**

| Agent | Job | Access |
|-------|-----|--------|
| Architect | Explore codebase, write shared contracts, partition work into N scopes | Read-only. Shuts down after planning. |
| Builder(s) | Implement partition with TDD, fix failures, commit code | Read/write scoped to partition files. |
| Verifier | Run checks, validate plan adherence, report failure_keys | Read-only. Cannot edit files. |
| Reviewer | Review PR diff against spec with priority tracking | GitHub CLI only. Can request screenshots. |

The orchestrator is a **thin coordinator** — it creates tasks, reads task metadata, and makes decisions. It never reads code or runs tests. Progress is visible in real time via `Ctrl+T` (task list).

## v3 — Builder Swarm

The architect analyzes the codebase and spec, then produces an **implementation contract**:
- Writes shared types/interfaces to disk (compilable, importable by all builders)
- Partitions the feature into N independent pieces with **non-overlapping file ownership**
- Maps every spec requirement to exactly one partition

Each builder gets a focused context window scoped to its own files. Two builders never edit the same file, eliminating merge conflicts. When verification fails, failures route back to the owning builder by file path.

**Backward compatible** — when the architect produces a single partition, the loop falls back to single-builder behavior with no scope restrictions.

### Builder count

| Setting | Behavior |
|---------|----------|
| `builder_count: auto` (default) | Architect decides based on codebase analysis (typically 2-5) |
| `builder_count: N` | Force exactly N builders |
| `max_builders: 5` (default) | Safety cap on the architect's recommendation |

### Per-builder stagnation

Stagnation detection runs per-builder. If a builder hits 3 identical failure sets and its partition is independent from others, that partition is marked `NEEDS_HUMAN` while the remaining builders continue. If the partition has dependencies, the loop aborts.

### Resume with partial teams

On resume, only incomplete partitions get builders. Completed partitions are skipped. The architect is never re-spawned — the contract is already on disk.

## Install

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

## Permissions

Tim Loop spawns up to 6+ agents that make many tool calls (file edits, test runs, git commands, `gh` CLI). In the default permission mode, **each tool call requires manual approval** — this creates significant friction during the automated loop.

**Easiest approach:** Run Claude Code with `--dangerously-skip-permissions` (or your alias for it). Teammates inherit the lead's permission mode, so all agents will run fully autonomously. Since Tim Loop already works in an isolated git worktree, the blast radius is contained to a throwaway branch.

```bash
claude --dangerously-skip-permissions
# then: /tim-loop docs/specs/your-feature.md
```

**Use caution.** Bypassing permissions means agents can execute any command without asking. Only do this when you trust the spec and are comfortable with automated git operations on your repo. Review the generated PR carefully before merging.

**Safer alternative:** Pre-approve common operations in `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(git *)",
      "Bash(pnpm *)",
      "Bash(npm *)",
      "Bash(tsc *)",
      "Bash(gh pr *)",
      "Bash(playwright-cli *)",
      "Edit(*)",
      "Write(*)"
    ]
  }
}
```

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- [Superpowers](https://github.com/anthropics/superpowers) plugin (provides TDD, code-review, worktree skills)
- [`gh` CLI](https://cli.github.com/) authenticated — needed for PR creation and review
- [Context7 MCP](https://github.com/upstash/context7) configured — agents verify library APIs against current docs
- [playwright-cli](https://github.com/anthropics/playwright-cli) (optional) — for browser-based E2E verification

## Usage

### 1. Generate a spec

```
/tim-spec add rate limiting to the API
```

Walks you through brainstorming, explores the codebase for architecture context, then outputs a structured spec to `docs/specs/` with prioritized requirements, test strategy, and risk assessment.

### 2. Run the loop

```
/tim-loop docs/specs/2026-02-28-rate-limiting.md
```

Progress updates show in your terminal and the task list (`Ctrl+T`):

```
Architect approved. Spawning 3 builders...
Cycle 1/3: Build complete (3/3 builders done). Starting verify...
Cycle 1/3: Verify FAIL (attempt 2/5, FIXABLE). Routing fixes to 2 builder(s)...
Cycle 1/3: Verify PASS. Publishing PR...
Cycle 1/3: Review PASS. PR #47 ready for human review.
```

### 3. Resume after abort

If the loop aborts, per-partition state is saved to `.tim-loop-resume.json` in the worktree:

```
/tim-loop --resume /path/to/worktree/.tim-loop-resume.json
```

Only incomplete partitions get new builders. Completed work is preserved.

### 4. Write specs manually

If you skip `/tim-spec`, your spec needs at minimum these sections:

```markdown
# Feature: Rate Limiting

## Goal
Prevent API abuse by enforcing per-user request limits.

## Requirements
- [ ] [P0] 100 requests per minute per user
- [ ] [P0] Return 429 with Retry-After header when exceeded
- [ ] [P1] Admin dashboard showing rate limit stats

## Acceptance Criteria
- Authenticated user making 101 requests in 60s gets 429 on the 101st
- Retry-After header value matches remaining cooldown seconds
```

Optional sections: `## Architecture`, `## Test Strategy`, `## Risk Assessment`, `## Open Questions`, `## Loop Config`, `## Verification`, `## Out of Scope`.

## Key Features

- **Architect-driven partitioning** — dedicated agent explores the codebase, writes shared contracts to disk, and splits work into N non-overlapping file scopes.
- **Parallel builders** — N builders work simultaneously, each with a focused context window scoped to their partition.
- **File-scoped failure routing** — verification failures route to the owning builder by file path. Builders only fix issues in their scope.
- **Per-builder stagnation** — stagnation detection per-builder. Stagnant partitions can be isolated while others continue.
- **Shared contracts** — architect writes compilable types/interfaces that builders import. Eliminates integration mismatches.
- **Task-driven coordination** — agents use TaskCreate/TaskUpdate. Progress visible via `Ctrl+T`.
- **Baseline verification** — pre-existing failures recorded before building. No false negatives.
- **Priority requirements** — `[P0]`/`[P1]`/`[P2]` tags determine build order and review strictness.
- **Incremental verification** — retries run previously-failed checks first before the full suite.
- **3-tier verification** — (1) Always: typecheck, lint, tests, build. (2) Platform-detected: Playwright, xctest, e2e. (3) Spec overrides.
- **Configurable loop** — spec overrides for cycles, retries, builder count, baseline, and more.
- **Abort and resume** — per-partition state saved to `.tim-loop-resume.json`. Resume spawns builders only for incomplete partitions.
- **Visual review** — reviewer can request screenshots from verifier for UI changes.
- **Backward compatible** — single partition = single builder with no scope restrictions.

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

## Design Principles

**Thin orchestrator / fat agents** — The orchestrator creates tasks and reads task metadata (verdicts, failure_keys, prognoses). All code reading, test running, and diff analysis happens in agents. This keeps the main context window clean enough to survive the full loop.

**Architect before builders** — The architect produces a partition plan and shared contracts before any builder is spawned. This prevents builders from stepping on each other's files and ensures integration contracts are explicit and importable.

**Iron Laws + Progressive Disclosure** — Each agent gets 5-6 critical rules in its spawn prompt (reliably followed) plus a reference file with detailed guidance (read on first turn). Fewer strong rules beat many weak ones.

**Task-driven state machine** — The shared task list IS the coordination layer. The orchestrator doesn't parse messages for verdicts — structured metadata on completed tasks provides clean, reliable signals for loop decisions.

**Route by file ownership** — Failures and review findings are routed to the builder that owns the relevant files. Two builders never fix the same file. Unroutable items default to builder-1.

## File Structure

```
skills/
├── tim-loop/
│   ├── SKILL.md           # Orchestrator (the loop)
│   ├── tim-architect.md   # Architect agent prompt + reference
│   ├── tim-builder.md     # Builder agent prompt + reference
│   ├── tim-verifier.md    # Verifier agent prompt + reference
│   ├── tim-reviewer.md    # Reviewer agent prompt + reference
│   ├── tim-verify.md      # 3-tier verification strategy
│   └── README.md          # Detailed docs
├── tim-spec/
│   └── SKILL.md           # Spec generation skill
commands/
├── tim-loop.md            # /tim-loop slash command
└── tim-spec.md            # /tim-spec slash command
```

## License

MIT

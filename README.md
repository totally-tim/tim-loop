# Tim Loop

An automated build-verify-review development loop for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Takes a feature spec, partitions the work across parallel builders — each in their own isolated git worktree — verifies with metric-driven keep/discard iteration, merges into an integration branch, and reviews the PR. Repeats until the reviewer passes or max cycles are exhausted.

```
/tim-spec add webhook retry logic  -->  brainstorm (or import gstack plan) + structured spec
/tim-loop docs/specs/2026-02-28-webhook-retries.md  -->  automated loop --> PR ready
```

## How It Works

```
SETUP: Spec --> Integration worktree --> Architect partitions work
       --> Per-builder worktrees created --> Baseline verification (guards + metric)

THE LOOP (up to 3 cycles):

  0.5 CONTRACT   (cycle 1 only) Builders propose done-criteria.
                  Verifier reviews. Max 2 rounds negotiation.
  1. BUILD        N builders work in parallel, each in their own worktree.
                  Each change: commit --> guard check --> metric check --> keep or discard.
                  Atomic iteration inspired by autoresearch.
  2. INTEGRATE    Reviewer merges builder branches into integration, one at a time.
                  Guard check after each merge. Identifies which merge broke what.
  3. VERIFY       Three-phase verification on integrated build:
                  Phase 1: Guard check (baseline invariants, non-negotiable).
                  Phase 2: Feature verification (metric tracking, structured plan adherence
                           with per-requirement evidence, interactive smoke check
                           with quality scoring).
                  Phase 3: Integration completeness (stubs, dead code, connections,
                           user journey smoke tests in real browser).
  4. PUBLISH      Push integration branch, create/update PR with priority checklist.
  5. REVIEW       Reviewer checks PR diff against spec by priority.
                  Spec Completeness Audit: requirement-by-requirement codebase search
                  for implementation + test evidence. Orchestrator validates audit.

  PASS --> Done. PR ready for human review.
  FAIL --> All agents shut down, fresh agents spawned for next cycle.
  ABORT --> Per-partition state saved for resume.
```

**Four agent roles:**

| Agent | Job | Access |
|-------|-----|--------|
| Architect | Explore codebase, write shared contracts to integration branch, partition work into N scopes | Writes shared contracts. Shuts down after planning. |
| Builder(s) | Implement partition with keep/discard iteration in isolated worktree | Read/write scoped to partition files in own worktree. |
| Verifier | Three-phase verification: guards, feature checks, integration completeness (stubs, dead code, connections, user journeys) | Read-only. Cannot edit files. Operates across worktrees. |
| Reviewer | Merge builder branches into integration, review PR diff against spec, run Spec Completeness Audit (requirement-by-requirement evidence search) | Git merge + GitHub CLI for code review. Local file reads in integration worktree for completeness audit. |

The orchestrator is a **thin coordinator** — it creates tasks, reads task metadata, and makes decisions. It never reads code or runs tests. Progress is visible in real time via `Ctrl+T` (task list).

## Per-Builder Worktree Isolation

Each builder gets its own git worktree, branched from the integration branch:

```
main (untouched)
│
├── worktree: tim-loop/{feature}/integration   ← architect writes contract here
│                                                 reviewer merges here
│
├── worktree: tim-loop/{feature}/builder-1     ← builder-1 works here (isolated)
├── worktree: tim-loop/{feature}/builder-2     ← builder-2 works here (isolated)
└── worktree: tim-loop/{feature}/builder-3     ← builder-3 works here (isolated)
```

**Why this matters:**
- Builder A's broken typecheck doesn't block Builder B
- Failures are unambiguous — it's their worktree, their problem
- Each builder can compile and test independently
- Integration bugs are caught explicitly when the reviewer merges branches

**Backward compatible** — when the architect produces a single partition, the loop creates one builder worktree with no scope restrictions.

## Keep/Discard Iteration (autoresearch-style)

Inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch) and [uditgoenka/autoresearch](https://github.com/uditgoenka/autoresearch), each builder follows an atomic iteration loop:

```
1. Make ONE atomic change (if you need "and" to describe it, split it)
2. Commit (before verifying — enables clean rollback)
3. Guard check: did I break existing functionality?
   ├── FAIL → git revert HEAD (immediate, no exceptions)
   └── PASS → continue
4. Metric check: did the feature metric improve?
   ├── IMPROVED → KEEP (commit stays)
   ├── SAME/WORSE → DISCARD (git revert HEAD, try different approach)
   └── (pass/fail mode: guard pass = keep)
5. Log iteration result → repeat
```

**Guard vs feature verification:**

| | Guard Check | Feature Verification |
|---|---|---|
| Purpose | Protect existing functionality | Track new functionality progress |
| On failure | Immediate revert (non-negotiable) | Report as failure, try different approach |
| Metric | Not tracked | Tracked (higher/lower is better) |

**Smart stuck escalation:** After 3 consecutive discards, the builder makes a strategic refine/pivot decision. If pivoting, it tries the opposite approach — combine near-misses, switch libraries, restructure. Only aborts if the rethink also fails.

**Scored evaluation with hard thresholds:** Verifier and auditor independently score the build across 6 dimensions (functional completeness, code health, integration coherence, implementation depth, test thoroughness, spec fidelity). Any dimension below 6/10 fails the build — even if all tests pass. Scoring criteria and calibration examples are centralized in `tim-evaluation-calibration.md`.

## Integration Completeness Verification (Phase 3)

The biggest pain point in large implementations: code passes every test but the feature is broken when you actually try to use it. Phase 3 catches this by verifying top-down — from the user's perspective.

**Phase 3 runs after guards and feature tests pass.** It catches:

| Check | What it finds | Example |
|-------|--------------|---------|
| **Stub scan** | TODO, FIXME, empty functions, hardcoded mocks | `createInvoice()` returns `null` instead of calling the API |
| **Dead export detection** | Components/functions built but never used | `InvoiceForm.tsx` exists but isn't rendered on any page |
| **Connection verification** | Cross-partition seams not wired up | API endpoint exists but frontend never calls it |
| **User journey smoke tests** | Feature unreachable through normal navigation | Invoice page exists but there's no link to it in the sidebar |

### User Journeys

The most powerful check. Tim-spec co-creates these with you during spec generation:

```markdown
## User Journeys
App entry: http://localhost:3000
Dev server: `npm run dev`

### Journey 1: Create an invoice
- [ ] Step 1 — Navigate: Click "Dashboard" in sidebar
  Checkpoint: Dashboard loads, "Invoices" section visible
- [ ] Step 2 — Navigate: Click "Invoices" → "Create Invoice"
  Checkpoint: Invoice form renders with amount, recipient, due date fields
- [ ] Step 3 — Action: Fill form, click Submit
  Checkpoint: Success toast, redirected to invoice list, new invoice visible
```

During verification, the verifier literally walks through these steps in a browser, taking screenshots at each checkpoint. If any step fails — the form doesn't render, the button is missing, the page 404s — it's caught before the PR is created.

### Connection Map

The architect produces a connection map in the implementation contract, documenting every cross-partition seam:

```
| Source | Target | Connection Type | What to verify |
|--------|--------|-----------------|----------------|
| POST /api/invoices | InvoiceForm submit | API call | Frontend calls endpoint |
| InvoiceForm component | /invoices/new page | Rendering | Component rendered on page |
| /invoices/new route | Sidebar nav | Navigation | Route linked in sidebar |
```

The verifier checks each connection with targeted greps and browser verification.

## gstack Integration (tim-spec)

Tim-spec can import planning artifacts from [gstack](https://github.com/garrytan/gstack) as a starting point for spec generation:

```
/tim-spec add rate limiting
```

If gstack planning output exists in `~/.gstack/projects/{slug}/`:
- Design docs (`*-design-*.md`) → Goal, Requirements, Risk Assessment
- Test plans (`*-test-plan-*.md`) → Test Strategy, Acceptance Criteria

The user reviews the extracted sections, assigns priorities, and adjusts before the spec is finalized. Brainstorming mode remains the default when no gstack artifacts exist.

### Metric-driven specs

Tim-spec now generates three optional sections that enable metric-driven iteration:

```markdown
## Metric
Command: `npm test -- --coverage | grep "All files" | awk '{print $4}'`
Direction: higher is better
Baseline: 72.3

## Guards
- `npx tsc --noEmit`
- `npm test -- --testPathIgnorePatterns="new-tests"`
- `npm run lint`

## Verify Command
npm test -- --coverage | grep "All files" | awk '{print $4}'
```

When present, tim-loop uses metric-driven keep/discard. Without them, it falls back to pass/fail mode.

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

**Easiest approach:** Run Claude Code with `--dangerously-skip-permissions` (or your alias for it). Teammates inherit the lead's permission mode, so all agents will run fully autonomously. Since Tim Loop works in isolated git worktrees, the blast radius is contained to throwaway branches.

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

Walks you through brainstorming (or imports gstack planning artifacts), co-creates user journeys with you, explores the codebase for architecture context, then outputs a structured spec to `docs/specs/` with prioritized requirements, user journeys, metric/guard configuration, test strategy, and risk assessment.

### 2. Run the loop

```
/tim-loop docs/specs/2026-02-28-rate-limiting.md
```

Progress updates show in your terminal and the task list (`Ctrl+T`):

```
Architect approved. Creating 3 builder worktrees...
Cycle 1/3: Build complete (builder-1: 5 keeps/2 discards, builder-2: 3 keeps/0 discards)...
Cycle 1/3: Integrating builder branches...
Cycle 1/3: Guards PASS. Feature verify PASS. Running integration completeness...
Cycle 1/3: Integration completeness: 1 stub, 0 dead exports, 2/3 journeys. Routing fixes...
Cycle 1/3: Review FAIL (1 blocking). Refreshing agents for cycle 2...
Cycle 2/3: Build complete. Integrating...
Cycle 2/3: Guards PASS. Feature verify PASS. Integration completeness: 0 stubs, 0 dead, 3/3 journeys PASS.
Cycle 2/3: Integration verify PASS. Metric: 72.3 → 91.4 (+19.1). Publishing...
Cycle 2/3: Review PASS. PR #47 ready for human review.
```

### 3. Resume after abort

If the loop aborts, per-partition state is saved to `.tim-loop-resume.json` in the integration worktree:

```
/tim-loop --resume /path/to/integration-worktree/.tim-loop-resume.json
```

Only incomplete partitions get new builders. Builder worktrees are preserved. Completed work is kept.

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

Optional but recommended: `## Metric`, `## Guards`, `## Verify Command` (enable metric-driven iteration), `## User Journeys` (enable browser-based integration smoke tests).

Other optional sections: `## Architecture`, `## Test Strategy`, `## Risk Assessment`, `## Open Questions`, `## Loop Config`, `## Verification`, `## Out of Scope`.

## Key Features

- **Per-builder worktree isolation** — each builder works in their own git worktree. No cascading build errors. Unambiguous failure attribution.
- **Keep/discard iteration** — autoresearch-style atomic commits with guard check + metric check. Keep improvements, discard regressions.
- **Guard vs feature verification** — guards protect existing functionality (non-negotiable revert). Feature verification tracks progressive improvement.
- **Smart stuck escalation** — 3 consecutive discards triggers a refine/pivot decision. Builder makes an explicit strategic choice before the orchestrator intervenes. Rethink uses remaining iteration budget, not a fixed 3.
- **Scored evaluation criteria** — verifier scores functional completeness, code health, integration coherence (1-10). Auditor scores implementation depth, test thoroughness, spec fidelity (1-10). Hard threshold: no dimension below 6. Fails even if tests pass.
- **Evaluator calibration** — centralized `tim-evaluation-calibration.md` with scoring rubrics, few-shot examples, and anti-leniency directives. Prevents the "evaluator talks itself into approving mediocre work" failure mode.
- **Mandatory contract negotiation** — on cycle 1, builders propose done-criteria before building. Verifier reviews testability. Done-contracts are wired into verification: the verifier checks "did the builder deliver what they committed to?" not just "does the code match the spec?" Done-contracts are persisted through resume and agent refresh.
- **Interactive smoke check** — after Tier 1 passes in Phase 2, verifier starts the dev server, navigates key routes, and screenshots critical states. Feeds into quality scores. Catches broken UX before full Phase 3.
- **Adaptive iteration budget** — architect recommends per-partition iteration budgets based on complexity. Simple partitions get 4-6 iterations, complex ones get 8-12. Global cap still applies.
- **Per-phase duration tracking** — TSV log includes `phase`, `duration_s`, `start_ts`, and `end_ts` columns (ISO 8601 UTC) for per-phase cost and bottleneck analysis.
- **Scope amplification** — tim-spec asks "What would make this 10/10?" after brainstorming, proposing P1/P2 features that round out the user experience.
- **Reviewer as integrator** — reviewer merges builder branches one at a time with guard checks after each merge. Identifies which merge broke what.
- **gstack import** — tim-spec can consume gstack design docs and test plans as starting points. Brainstorming remains the default.
- **Metric-driven specs** — optional `## Metric`, `## Guards`, `## Verify Command` sections enable progressive improvement tracking. Falls back to pass/fail without them.
- **Integration completeness verification** — Phase 3 catches the "green tests, broken app" problem: stub scan, dead export detection, connection verification, and user journey smoke tests in a real browser.
- **User journey smoke tests** — co-created with the user during spec generation. Verifier walks through each journey in a browser, taking screenshots at every checkpoint. Catches missing pages, unhooked features, and broken navigation.
- **Connection mapping** — architect maps every cross-partition seam (API↔UI, component↔page, route↔navigation). Verifier checks each connection during integration completeness.
- **TSV progress log** — every builder iteration, integration result, and review outcome logged to `tim-loop-results.tsv` for observability.
- **Architect-driven partitioning** — dedicated agent explores the codebase, writes shared contracts to disk, and splits work into N non-overlapping file scopes.
- **Parallel builders** — N builders work simultaneously, each with a focused context window scoped to their partition.
- **Task-driven coordination** — agents use TaskCreate/TaskUpdate. Progress visible via `Ctrl+T`.
- **Baseline verification** — pre-existing failures and metric values recorded before building. No false negatives.
- **Spec Completeness Audit** — reviewer performs requirement-by-requirement codebase search for implementation and test evidence. Produces a structured `requirement_audit` array. Any P0 without both implementation and test evidence is BLOCKING. The orchestrator independently validates the audit before accepting a PASS verdict — defense in depth across verifier, reviewer, and orchestrator.
- **Priority requirements** — `[P0]`/`[P1]`/`[P2]` tags determine build order and review strictness.
- **3-tier verification** — (1) Always: typecheck, lint, tests, build. (2) Platform-detected: Playwright, xctest, e2e. (3) Spec overrides.
- **Configurable loop** — spec overrides for cycles, iterations, builder count, metric mode, and more.
- **Abort and resume** — per-partition state saved to `.tim-loop-resume.json`. Resume spawns builders only for incomplete partitions. All worktrees preserved.
- **Agent refresh between cycles** — all agents shut down and re-spawn with fresh context windows between outer cycles. Verifier discovery carried forward.
- **Backward compatible** — single partition = single builder worktree with no scope restrictions.
- **Defensive review** — Phase 2 verification includes a 4-category defensive review: input validation at API boundaries, security patterns (CSV injection, SQL injection, XSS, command injection, path traversal), atomicity/error handling (transactions, rollback), and data consistency. Scoped to new code plus new data paths to existing sinks. Catches the class of issues that external AI code review finds but per-file testing misses.
- **Typed message filtering** — orchestrator suppresses idle messages from completed builders but always processes escalation-prefixed messages (QUESTION, NEEDS_HUMAN, SCOPE_CONFLICT, CONTRACT_ISSUE). No builder shutdown/spawn cycling.
- **Architect schema validation** — partition implementation notes use a structured Decision/Rationale/Cross-partition-dependency schema. Forces clarity without stripping technical detail.
- **Builder subagent mode** — for HIGH complexity partitions (13+ requirements or 8+ files across 3+ directories), builders dispatch sequential subagents for focused implementation chunks. Builder retains commit/revert/keep-discard ownership. Subagents only write code.
- **Subagent-powered auditor** — when total requirements exceed 15, the auditor dispatches per-partition subagents for parallel deep-reading. Cross-partition checks (wiring, reachability, contract usage) stay centralized. Fallback to direct mode on subagent failure.
- **Constants ownership** — architect Iron Law: all shared constants and types must live in architect-owned contract files. No partition may define a constant another partition also needs.

## Configuration

Defaults are overridable per-spec via the `## Loop Config` section:

| Setting | Default | Spec Override |
|---------|---------|---------------|
| Outer cycles | 3 | `max_outer_cycles: N` |
| Builder iterations | 8 | `max_builder_iterations: N` |
| Plan approval (cycle 1) | true | `require_plan_approval: false` |
| Baseline verification | true | `skip_baseline: true` |
| Builder count | auto | `builder_count: N` or `auto` |
| Max builders | 5 | `max_builders: N` |
| Metric mode | auto | `metric_mode: metric` or `pass_fail` |

## Design Principles

**Thin orchestrator / fat agents** — The orchestrator creates tasks and reads task metadata (verdicts, failure_keys, metrics, prognoses). All code reading, test running, and diff analysis happens in agents. This keeps the main context window clean enough to survive the full loop.

**Architect before builders** — The architect produces a partition plan and shared contracts in the integration worktree before any builder worktree is created. Builder worktrees branch from integration, inheriting the contract automatically.

**Worktree isolation** — Each builder gets a complete, independent copy of the repo. No shared filesystem state during build. Integration happens explicitly through git merge, with guard checks at each step.

**Keep/discard discipline** — Inspired by autoresearch: one atomic change, commit before verifying, mechanical metric extraction, keep or discard based on direction. Git history preserves every attempt for pattern analysis.

**Guard before feature** — Guard checks (baseline invariants) are non-negotiable. A change that improves the feature metric but breaks existing tests is always reverted. Regressions are never tolerated.

**Deterministic skeleton, flexible flesh** — The orchestrator's phase sequence (BUILD → INTEGRATE → VERIFY → PUBLISH → REVIEW) and all branching decisions (merge conflict? guard fail? NEEDS_HUMAN?) are explicit pseudocode — the model follows the state machine exactly. Implementation details within each phase (how to iterate results, count discards, format TSV rows) are described as intent, trusting the model to execute. Inspired by [Anthropic's lessons from building Claude Code](https://www.anthropic.com/engineering/claude-code-agent-lessons): keep flow control deterministic, simplify everything else.

**Iron Laws + Progressive Disclosure** — Each agent gets 5-8 critical rules in its spawn prompt (reliably followed) plus a reference file with detailed guidance (read on first turn). Fewer strong rules beat many weak ones. Both tim-loop and tim-spec use `effort: max` to ensure maximum thinking time for complex orchestration.

**Task-driven state machine** — The shared task list IS the coordination layer. The orchestrator doesn't parse messages for verdicts — structured metadata on completed tasks provides clean, reliable signals for loop decisions.

**Top-down verification** — Phase 3 (integration completeness) verifies the feature works as a product, not just as code. Stub scans, dead export detection, connection verification, and user journey smoke tests catch the "green tests, broken app" problem that bottom-up verification misses.

**Route by file ownership** — Failures and review findings are routed to the builder that owns the relevant files. Two builders never fix the same file. Unroutable items default to builder-1.

**Defense in depth, not just existence checking** — The loop verifies three things independently: does the feature exist (plan adherence), is the feature robust (defensive review), and is the feature reachable (integration completeness). External code review tools consistently found security and atomicity issues that per-file testing missed. The defensive review checklist catches these inside the loop.

**Subagents for scale, not for decomposition** — When agents hit context or complexity limits, they dispatch subagents for grunt work (searching, reading, implementing chunks) while retaining ownership of judgment calls (keep/discard, scoring, cross-partition checks). The parent agent orchestrates; subagents are hands, not brains.

## File Structure

```
skills/
├── tim-loop/
│   ├── SKILL.md           # Orchestrator (the loop)
│   ├── tim-architect.md   # Architect agent prompt + reference
│   ├── tim-builder.md     # Builder agent prompt + reference
│   ├── tim-verifier.md    # Verifier agent prompt + reference
│   ├── tim-reviewer.md    # Reviewer agent prompt + reference
│   ├── tim-verify.md      # Three-phase verification strategy (guard + feature + integration completeness)
│   ├── tim-evaluation-calibration.md  # Scoring criteria, thresholds, few-shot calibration, anti-leniency
│   └── README.md          # Detailed docs
├── tim-spec/
│   └── SKILL.md           # Spec generation skill (brainstorming + gstack import)
commands/
├── tim-loop.md            # /tim-loop slash command
└── tim-spec.md            # /tim-spec slash command
```

## License

MIT

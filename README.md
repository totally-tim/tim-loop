# Tim Loop

An automated build-verify-review development loop for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Takes a feature spec, partitions the work across parallel builders — each in their own isolated git worktree — verifies with metric-driven keep/discard iteration, merges into an integration branch, and reviews the PR. Repeats until the reviewer passes or max cycles are exhausted.

```
/tim-spec add webhook retry logic  -->  guided brainstorming + structured spec
/tim-loop docs/specs/2026-02-28-webhook-retries.md  -->  automated loop --> PR ready
```

## How It Works

```
SETUP: Spec pre-flight (validate verify command, guards, paths)
       --> Integration worktree + .tim-loop/{context,state}/ dirs
       --> Shared context files written ONCE (read-by-path, not re-embedded)
       --> Architect framework pre-flight (Context7 against the contract itself,
           grep cross-run lessons for known framework gotchas)
       --> Architect partitions work + writes contract.md to context dir
       --> Per-builder worktrees created
       --> Baseline verification (guards + metric, metric_sanity is a hard gate)

THE LOOP (up to 3 cycles):

  0.5 CONTRACT    Conditional (default: if_needed). Negotiate only when spec has
                  Open Questions affecting a partition OR a HIGH partition uses a
                  novel library. Most loops skip this step.
  1. BUILD        N builders work in parallel, each in their own worktree.
                  Each change: commit --> guard check --> metric check --> keep or discard.
                  Before reporting done: Done Self-Check (spec-phrase grep,
                  stub-shape parity, compiler-trap audit).
  2. INTEGRATE    Reviewer runs three stages:
                  A. Sequential merges + per-merge guards
                  B. Apply contract-declared post-merge handoffs (path rewrites)
                  C. POST-HANDOFF-GUARD — re-run guards (catches stub-vs-real drift)
                  Monotonic-progress on re-attempts: keep going while failure count
                  shrinks or category changes; stop on stagnation.
  3. VERIFY+AUDIT Run in PARALLEL, both before publish:
                  Verifier: Phase 1 (guards), Phase 2 (features + live data + plan
                  adherence + defensive review), Phase 3 (integration completeness:
                  stubs, dead exports, connections, user journeys, protocols, deploy).
                  Auditor: deep source-read of every requirement + acceptance criterion,
                  cross-partition wiring, entry-point reachability, compliance report.
                  Combined verdict gates publish.
  4. PUBLISH      Only after VERIFY+AUDIT pass. Push (force-with-lease for cycle 2+),
                  create/update PR with priority checklist + compliance report.
  5. REVIEW       Post-publish: CI + code quality only. Audit already happened.

  PASS --> Done. Lessons artifact written. PR ready for human review.
  FAIL --> Agents refresh, findings routed via Failure-Key Routing Matrix.
  ABORT --> Per-partition state saved for resume (.tim-loop/state/).
```

| Agent | Job | Access |
|-------|-----|--------|
| Architect | Explore codebase + grep cross-run lessons, run framework pre-flight via Context7 against the contract, write shared contracts, partition work into N scopes with structured P0 matrix and stub-shape parity | Writes shared contracts. Shuts down after planning. |
| Builder(s) | Implement partition with keep/discard iteration in isolated worktree. Done Self-Check before reporting complete. | Read/write scoped to partition files in own worktree. |
| Verifier | Three-phase verification: guards, feature checks (including live data verification), integration completeness | Read-only. Cannot edit files. Operates across worktrees. |
| Reviewer | Three-stage INTEGRATE (per-merge guards + handoff + POST-HANDOFF-GUARD), then PUBLISH, then post-publish CI + code quality REVIEW. Routes cross-partition fixes. | Git merge + GitHub CLI. Integration worktree access. |
| Auditor | Deep spec completeness audit — runs PRE-publish in parallel with verifier: requirement-by-requirement source reading, implementation depth scoring, entry-point reachability tracing | Read-only. Spawned just-in-time for the pre-publish verify+audit gate. |

**Five agent roles** (architect shuts down after planning, auditor spawns just-in-time for the pre-publish verify+audit phase):

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
| **Protocol consistency** | Shared interface signatures don't match implementations | Protocol has 1 param but implementation has 2 |
| **Deployment readiness** | Build output incompatible with deploy target | `output: 'standalone'` in next.config.js but start command uses `next start` |

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
- **Browser verification** (at least one): `mcp__claude-in-chrome__*` (preferred, native Claude MCP) or [playwright-cli](https://github.com/anthropics/playwright-cli) — required for frontend features with user journeys

## Usage

### 1. Generate a spec

```
/tim-spec add rate limiting to the API
```

Walks you through guided brainstorming, co-creates user journeys with you, explores the codebase for architecture context, verifies API data mappings for external-API features, validates the metric command, then outputs a structured spec to `docs/specs/` with prioritized requirements, user journeys, data mappings, metric/guard configuration, spike tasks, test strategy, and risk assessment.

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

Optional but recommended: `## Metric`, `## Guards`, `## Verify Command` (enable metric-driven iteration), `## User Journeys` (enable browser-based integration smoke tests), `## Data Mapping` (for API-driven features), `## Spike Tasks` (verify API assumptions before building).

Other optional sections: `## Architecture`, `## Test Strategy`, `## Risk Assessment`, `## Open Questions`, `## Loop Config`, `## Verification`, `## Compiler Traps`, `## Out of Scope`.

## Key Features

### v4 (post Spec 02 — Auth retro)

- **Shared context files** — spec/contract/strategy written once to `.tim-loop/context/`; agents reference via absolute path on first turn instead of embedding. Cuts spawn prompts from ~50KB to ~5KB and saves ~100-150K tokens per multi-builder cycle.
- **Durable phase artifacts** — every phase writes a JSON to `.tim-loop/state/` (baseline.json, integrate-N.json, verify-N.json, audit-N.json, review-N.json). Survives task-ID drift; clean resume.
- **Pre-publish audit** — auditor runs in parallel with verifier BEFORE publish. PR only goes up if both pass. Eliminates the force-push cycles that happen when post-publish auditing catches BLOCKING bugs.
- **Conditional contract negotiation** — defaults to `if_needed`. Triggers only on (a) Open Questions affecting a specific partition or (b) HIGH-complexity partition using a library not yet in the codebase. Cuts ~80K tokens of theater on well-specified work; keeps the safety net when ambiguity actually demands it.
- **POST-HANDOFF-GUARD** — INTEGRATE phase runs three stages: per-merge guards (A), contract-declared post-merge handoffs (B), then full guard suite re-run (C). Catches stub-vs-real-impl drift that per-merge guards miss.
- **Monotonic-progress re-integration** — no fixed cap. Continue while progress is strict (fewer failure_keys OR changed category). Stop only on stagnation (same failure_keys two consecutive attempts). Doesn't punish productive iteration.
- **Spec pre-flight** — orchestrator validates verify command, guards, and file references on the clean tree before any agent spawn. Hard-aborts at baseline if metric_sanity flags the verify command as broken (was advisory, now a gate).
- **Architect framework pre-flight** — Context7 against the contract itself, not just builder code. Catches Auth.js v5 edge-split, Web Crypto vs `node:crypto`, `trustHost`-style gotchas at design time.
- **Structured P0 coverage matrix** — architect contract includes a mechanically-lintable table mapping every P0 + acceptance criterion to its owning partition, owning file(s), and test file(s). Orchestrator rejects the contract on missing rows or duplicate file ownership.
- **Stub-shape lint** — architect contract review verifies that cross-partition stub signatures match the corresponding real type signatures exactly. Catches the bug class that drove most of the Spec 02 retro's re-integration cycles.
- **Types-and-augmentations connections** — connections map now distinguishes function-call seams from type/augmentation/re-export seams. Forces the architect to declare cross-partition type dependencies that grep alone would miss.
- **Builder Done Self-Check** — before reporting complete, builders run a spec-phrase grep (every P0 phrase has a code match in their files), stub-shape parity check, and compiler-trap audit. Catches the misses that the auditor used to flag downstream.
- **Failure-Key Routing Matrix** — explicit table in SKILL.md mapping every failure_key category to its default routing target. Removes orchestrator guesswork on fix attribution.
- **Dual-channel reporting** — verdict-bearing tasks instruct agents to post results via BOTH TaskUpdate AND SendMessage. Protects against stale task IDs (the Spec 02 retro saw ~7 tasks return "Task not found" mid-loop).
- **Lessons-learned artifact** — every terminal cycle writes `~/.claude/skills/tim-loop/lessons/{date}-{feature}.md`. The architect greps this directory on first turn for cumulative framework patterns across runs.
- **Force-push hygiene** — re-pushes after cycle 2+ integration rewrites use `--force-with-lease`. Refuses if the remote moved, preventing data loss.

### Core (pre-v4, still in place)

- **Per-builder worktree isolation** — each builder works in their own git worktree. No cascading build errors. Unambiguous failure attribution.
- **Keep/discard iteration** — autoresearch-style atomic commits with guard check + metric check. Keep improvements, discard regressions.
- **Guard vs feature verification** — guards protect existing functionality (non-negotiable revert). Feature verification tracks progressive improvement.
- **Smart stuck escalation** — 3 consecutive discards triggers a refine/pivot decision. Builder makes an explicit strategic choice before the orchestrator intervenes. Rethink uses remaining iteration budget, not a fixed 3.
- **Scored evaluation criteria** — verifier scores functional completeness, code health, integration coherence (1-10). Auditor scores implementation depth, test thoroughness, spec fidelity (1-10). Hard threshold: no dimension below 6. Fails even if tests pass.
- **Evaluator calibration** — centralized `tim-evaluation-calibration.md` with scoring rubrics, few-shot examples, and anti-leniency directives.
- **Interactive smoke check** — after Tier 1 passes in Phase 2, verifier starts the dev server, navigates key routes, and screenshots critical states. Feeds into quality scores. Catches broken UX before full Phase 3.
- **Adaptive iteration budget** — architect recommends per-partition iteration budgets based on complexity. Simple partitions get 4-6 iterations, complex ones get 8-12. Global cap still applies.
- **Per-phase duration tracking** — TSV log includes `phase`, `duration_s`, `start_ts`, and `end_ts` columns (ISO 8601 UTC) for per-phase cost and bottleneck analysis.
- **Scope amplification** — tim-spec asks "What would make this 10/10?" after brainstorming, proposing P1/P2 features that round out the user experience.
- **Reviewer as integrator** — reviewer merges builder branches one at a time with guard checks after each merge. Identifies which merge broke what.
- **Metric-driven specs** — optional `## Metric`, `## Guards`, `## Verify Command` sections enable progressive improvement tracking. Falls back to pass/fail without them. Metric commands are validated during spec generation to prevent broken metrics.
- **Data mapping verification** — for API-driven features, tim-spec verifies the semantic mapping between API fields and UI labels before generating the spec. Catches "API field doesn't mean what the label says" errors.
- **Spike task rigor** — spike tasks now require exact query parameters, full response parsing, and field-by-field verification. No more `curl | head -c 500` truncated checks.
- **Live data verification** — Phase 2b fetches each API route and verifies every field the UI depends on exists and is non-null. Catches "code compiles but API doesn't return expected data" failures.
- **Integration completeness verification** — Phase 3 catches the "green tests, broken app" problem: stub scan, dead export detection, connection verification, user journey smoke tests in a real browser, protocol consistency, and deployment readiness.
- **Deployment readiness** — Phase 3f checks that build output is compatible with the deployment target (Next.js standalone vs `next start`, Dockerfile validity, Railway/Fly config). Catches deploy-time failures before they happen.
- **Metric sanity checking** — during baseline verification, the metric command is cross-checked against the test runner. Broken metrics (e.g., always returns 2 when there are 100 tests) are flagged before builders start.
- **User journey smoke tests** — co-created with the user during spec generation. Verifier walks through each journey in a browser (via `mcp__claude-in-chrome__*` or `playwright-cli`), taking screenshots at every checkpoint. Catches missing pages, unhooked features, and broken navigation. **Browser verification is mandatory for frontend features** — if no browser tool is available, the build blocks with `NEEDS_HUMAN`.
- **Cross-partition fix routing** — dead exports and connection failures that span partition boundaries route to the reviewer (who has the integration worktree) instead of to builders who can't see each other's files.
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
| Contract negotiation | if_needed | `contract_negotiation: off` / `if_needed` / `always` |
| Baseline verification | true | `skip_baseline: true` |
| Builder count | auto | `builder_count: N` or `auto` |
| Max builders | 5 | `max_builders: N` |
| Metric mode | auto | `metric_mode: metric` or `pass_fail` |

Re-integration is governed by monotonic-progress (no fixed cap): continue while
failure_keys count strictly decreases or category changes; stop on stagnation.

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
│   ├── tim-auditor.md     # Auditor agent prompt + reference (runs pre-publish)
│   ├── tim-verify.md      # Three-phase verification strategy (guard + feature + integration completeness)
│   ├── tim-evaluation-calibration.md  # Scoring criteria, thresholds, few-shot calibration, anti-leniency
│   ├── lessons/           # Cumulative cross-run lessons (architect greps on first turn)
│   └── README.md          # Detailed docs
├── tim-spec/
│   └── SKILL.md           # Spec generation skill (guided brainstorming)
commands/
├── tim-loop.md            # /tim-loop slash command
└── tim-spec.md            # /tim-spec slash command
```

Per-run, in the integration worktree:
```
<integration-worktree>/.tim-loop/
├── context/               # Read-once shared context (paths referenced from agent prompts)
│   ├── spec.md
│   ├── contract.md        # Architect writes here directly
│   ├── verify-strategy.md
│   ├── evaluation-calibration.md
│   ├── requirements.md
│   ├── acceptance-criteria.md
│   ├── compiler-traps.md
│   ├── connections.md
│   ├── partition-assignments.md
│   └── user-journeys.md
├── state/                 # Per-phase artifacts (durable across task-ID drift / abort)
│   ├── baseline.json
│   ├── integrate-{cycle}.json
│   ├── verify-{cycle}.json
│   ├── audit-{cycle}.json
│   └── review-{cycle}.json
└── results.tsv            # Legacy progress log (kept for backward compatibility)
```

## License

MIT

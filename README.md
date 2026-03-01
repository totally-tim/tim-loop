# Tim Loop

An automated build-verify-review development loop for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Takes a feature spec, builds it with TDD in an isolated worktree, verifies independently, publishes a PR, and reviews it — repeating until the reviewer passes or max cycles are exhausted.

```
/tim-spec add webhook retry logic  -->  brainstorm + structured spec
/tim-loop docs/specs/2026-02-28-webhook-retries.md  -->  automated loop --> PR ready
```

## How It Works

```
SETUP: Spec --> Worktree --> 3 agents --> Baseline verification

THE LOOP (up to 3 cycles):

  1. PLAN         Builder submits build plan for approval (cycle 1 only)
  2. BUILD        Builder creates sub-tasks, implements with strict TDD
  3. VERIFY       Independent verifier runs checks against baseline
  3b. FIX         If verify fails, builder fixes (up to 5 retries)
                  Stagnation detection: 3 identical failures = abort
  4. PUBLISH      Commit, push, create/update PR with priority checklist
  5. REVIEW       Reviewer checks PR diff against spec by priority

  PASS --> Done. PR ready for human review.
  FAIL --> Findings sent to builder, next cycle starts.
  ABORT --> State saved for resume.
```

**Three agents, single responsibility each:**

| Agent | Job | Access |
|-------|-----|--------|
| Builder | Implement spec with TDD, create sub-tasks, commit code | Read/write code, run commands, git |
| Verifier | Run checks, validate plan adherence, report failure_keys | Read-only. Cannot edit files. |
| Reviewer | Review PR diff against spec with priority tracking | GitHub CLI only. Can request screenshots. |

Progress visible in real time via `Ctrl+T` (task list). The orchestrator coordinates via tasks — it never reads code or runs tests.

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

Tim Loop spawns 3 agents that make many tool calls (file edits, test runs, git commands, `gh` CLI). In the default permission mode, **each tool call requires manual approval** — this creates significant friction during the automated loop.

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

You'll see one-line progress updates and can check `Ctrl+T` for the full task list:

```
Cycle 1/3: Plan approved. Builder creating sub-tasks...
Cycle 1/3: Build complete (6/6 sub-tasks done). Starting verify...
Cycle 1/3: Verify FAIL (attempt 2/5, FIXABLE). Builder fixing...
Cycle 1/3: Verify PASS. Publishing PR...
Cycle 1/3: Review PASS. PR #47 ready for human review.
```

### 3. Resume after abort

If the loop aborts, state is saved to `.tim-loop-resume.json` in the worktree:

```
/tim-loop --resume /path/to/worktree/.tim-loop-resume.json
```

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

- **Task-driven coordination** — agents use TaskCreate/TaskUpdate. Progress visible via `Ctrl+T`.
- **Baseline verification** — pre-existing failures recorded before building. No false negatives.
- **Plan approval** — builder submits a build plan for review before coding (cycle 1).
- **Priority requirements** — `[P0]`/`[P1]`/`[P2]` tags determine build order and review strictness.
- **Granular sub-tasks** — builder creates 5-6 sub-tasks for real-time progress tracking.
- **Incremental verification** — retries run previously-failed checks first before the full suite.
- **Stagnation detection** — 3 identical failure_key sets aborts instead of wasting retries.
- **Configurable loop** — spec overrides for cycle counts, retries, plan approval, baseline.
- **Abort and resume** — state saved to `.tim-loop-resume.json` for later continuation.
- **Visual review** — reviewer can request screenshots from verifier for UI changes.

## Design Principles

**Thin orchestrator / fat agents** — The orchestrator creates tasks and reads task metadata (verdicts, failure_keys, prognoses). All real work (code reading, test running, diff analysis) happens in agents. This keeps the main context window clean enough to survive the full loop.

**Iron Laws + Progressive Disclosure** — Each agent gets 5-6 critical rules in its spawn prompt (reliably followed) plus a reference file with detailed guidance (read on first turn). Fewer strong rules beat many weak ones.

**Task-driven state machine** — The shared task list IS the coordination layer. The orchestrator doesn't parse messages for verdicts — structured metadata on completed tasks provides clean, reliable signals for loop decisions.

**3-tier verification** — (1) Always: typecheck, lint, tests, build. (2) Platform-detected: Playwright for web, xctest for iOS, e2e suites, etc. (3) Spec override: custom checks defined in the spec.

## Configuration

Defaults are overridable per-spec via the `## Loop Config` section:

| Setting | Default | Spec Override |
|---------|---------|---------------|
| Outer cycles | 3 | `max_outer_cycles: N` |
| Inner retries | 5 | `max_inner_retries: N` |
| Plan approval (cycle 1) | true | `require_plan_approval: false` |
| Baseline verification | true | `skip_baseline: true` |

## File Structure

```
skills/
├── tim-loop/
│   ├── SKILL.md           # Orchestrator (the loop)
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

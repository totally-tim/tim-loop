# Tim Loop

An automated build-verify-review development loop for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Takes a feature spec, builds it with TDD in an isolated worktree, verifies independently, publishes a PR, and reviews it — repeating until the reviewer passes or max cycles are exhausted.

```
/tim-spec "add webhook retry logic"  -->  brainstorm + structured spec
/tim-loop docs/specs/2026-02-28-webhook-retries.md  -->  automated loop --> PR ready
```

## How It Works

```
SETUP: Spec --> Worktree --> 3 agents learn codebase in parallel

THE LOOP (up to 3 cycles):

  1. BUILD        Builder implements with strict TDD
  2. VERIFY       Independent verifier runs all checks
  2b. FIX         If verify fails, builder fixes (up to 5 retries)
  3. PUBLISH      Commit, push, create/update PR
  4. REVIEW       Reviewer checks PR diff against spec

  PASS --> Done. PR ready for human review.
  FAIL --> Findings sent to builder, next cycle starts.
```

**Three agents, single responsibility each:**

| Agent | Job | Access |
|-------|-----|--------|
| Builder | Implement spec with TDD, commit code | Read/write code, run commands, git |
| Verifier | Run checks, validate plan adherence | Read-only. Cannot edit files. |
| Reviewer | Review PR diff against spec | GitHub CLI only. No local file access. |

The orchestrator (your session) coordinates via short status messages — it never reads code or runs tests, keeping its context window clean for the full loop.

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

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- [Superpowers](https://github.com/anthropics/superpowers) plugin (provides TDD, code-review, worktree skills)
- [`gh` CLI](https://cli.github.com/) authenticated — needed for PR creation and review
- [Context7 MCP](https://github.com/upstash/context7) configured — agents verify library APIs against current docs
- [playwright-cli](https://github.com/anthropics/playwright-cli) (optional) — for browser-based E2E verification

## Usage

### 1. Generate a spec

```
/tim-spec "add rate limiting to the API"
```

Walks you through brainstorming, then outputs a structured spec to `docs/specs/`.

### 2. Run the loop

```
/tim-loop docs/specs/2026-02-28-rate-limiting.md
```

You'll see one-line progress updates:

```
Cycle 1/3: Build complete. Starting verify...
Cycle 1/3: Verify FAIL (attempt 2/5, FIXABLE). Builder fixing...
Cycle 1/3: Verify PASS. Publishing PR...
Cycle 1/3: Review PASS. PR #47 ready for human review.
```

### 3. Write specs manually

If you skip `/tim-spec`, your spec needs at minimum these sections:

```markdown
# Feature: Rate Limiting

## Goal
Prevent API abuse by enforcing per-user request limits.

## Requirements
- [ ] 100 requests per minute per user
- [ ] Return 429 with Retry-After header when exceeded

## Acceptance Criteria
- Authenticated user making 101 requests in 60s gets 429 on the 101st
- Retry-After header value matches remaining cooldown seconds
```

Optional sections: `## Architecture`, `## Verification`, `## Out of Scope`.

## Design Principles

**Thin orchestrator / fat agents** — The orchestrator only tracks cycle numbers, verdicts, and prognoses. All real work (code reading, test running, diff analysis) happens in agents. This keeps the main context window clean enough to survive 3 full cycles.

**Iron Laws + Progressive Disclosure** — Each agent gets 5 critical rules in its spawn prompt (reliably followed) plus a reference file with detailed guidance (read on first turn). Based on research showing LLMs follow ~150 instructions with reasonable consistency — fewer strong rules beat many weak ones.

**3-tier verification** — (1) Always: typecheck, lint, tests, build. (2) Platform-detected: Playwright for web, xctest for iOS, e2e suites, etc. (3) Spec override: custom checks defined in the spec.

## Configuration

Edit `~/.claude/skills/tim-loop/SKILL.md` to change defaults:

| Setting | Default |
|---------|---------|
| Outer cycles | 3 |
| Inner retries | 5 |
| TDD | Strict |
| Worktree | Always |

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

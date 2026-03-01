# Tim Loop — Verification Strategy

Reference document for the verifier agent. Defines what to check and how.

## Baseline Mode

When running baseline verification (before builder makes changes):
- Run all Tier 1 checks on the clean worktree
- Record every failure as a `baseline_failure` key
- Do NOT run Tier 2/3 (no changes to verify yet)
- Store results in task metadata: `{ baseline_failures: [...] }`

## Incremental Mode (attempt 2+)

When previous failure_keys are provided:
1. Parse failure_keys to identify which checks failed
2. Run ONLY those checks first
3. If they now pass → run the full suite
4. If they still fail → stop and report immediately

This avoids re-running the entire suite when the builder only fixed specific issues.

## Tier 1 — Always Run (universal)

Run these checks. Typecheck and lint can run in parallel since they're independent.
Tests and build run sequentially after.

```
┌──────────────┐  ┌──────────────┐
│  Typecheck   │  │    Lint       │   ← parallel
└──────┬───────┘  └──────┬───────┘
       │                 │
       └────────┬────────┘
                │
         ┌──────▼───────┐
         │  Unit Tests   │   ← sequential (only if typecheck + lint pass)
         └──────┬───────┘
                │
         ┌──────▼───────┐
         │    Build      │   ← sequential (only if tests pass)
         └──────────────┘
```

| Check | How to detect command | Example |
|-------|----------------------|---------|
| Type checking | `tsconfig.json` → `tsc --noEmit`; `Package.swift` → `swift build`; `*.py` → `mypy` or `pyright` if configured | `pnpm typecheck` or `tsc --noEmit` |
| Linting | `eslint.config.*` → `eslint`; `.swiftlint.yml` → `swiftlint`; `ruff.toml` → `ruff check` | `pnpm lint` |
| Unit tests | `vitest.config.*` → `vitest`; `jest.config.*` → `jest`; `*.xcodeproj` → `xcodebuild test`; `pytest.ini` → `pytest` | `pnpm test` |
| Build | `package.json` → `pnpm build`; `Makefile` → `make`; `*.xcodeproj` → `xcodebuild build` | `pnpm build` |

**Detection strategy:** Check the project root for config files. Use package.json scripts when available (`pnpm test`, `pnpm build`, `pnpm lint`, `pnpm typecheck`). Fall back to direct tool invocation.

**Monorepo handling:** If a monorepo root has workspace-level scripts (e.g., `pnpm test` runs all), use those. If a specific package was changed, also run `pnpm --filter <pkg> test` for targeted feedback.

## Tier 2 — Platform Detection (agent-detected)

Check for these signals and run the corresponding verification. Only run checks relevant to files that changed.

| Signal | Verification Action | Notes |
|--------|-------------------|-------|
| `playwright` in package.json deps | `pnpm exec playwright test` or `npx playwright test` | Start dev server first if needed |
| `cypress` in package.json deps | `pnpm exec cypress run` | Start dev server first if needed |
| `.xcodeproj` or `Package.swift` present | `xcodebuild test -scheme <scheme> -destination 'platform=iOS Simulator,name=iPhone 16'` | Detect scheme from project |
| `vitest.config.e2e.ts` or `jest.config.e2e.ts` | Run E2E suite: `pnpm test:e2e` or equivalent | May need test infra (Docker, DB) |
| `docker-compose*.test.yml` present | `docker compose -f <file> up -d` before E2E, `down` after | Spin up test infra first |
| `apps/web/` or `src/pages/` changed | Playwright smoke on `http://localhost:3000` | Start dev server, run smoke tests |
| `*.swift` files changed | `swift test` or `xcodebuild test` | Run in package/project dir |
| Contract test files (`*.contract.test.*`) | Run contract test suite | Often separate config |
| `*.spec.ts` with `@playwright/test` import | `pnpm exec playwright test <file>` | Run specific spec files |
| Smoke test config (`vitest.config.smoke.*`) | Run smoke suite | May need running server |
| `playwright-cli` available | Use `playwright-cli` for interactive browser verification | Snapshot-based validation |

**When using playwright-cli for interactive browser verification:**
1. Start the dev server if not running
2. `playwright-cli open http://localhost:<port>`
3. Navigate to pages affected by the change
4. `playwright-cli snapshot` to capture current state
5. Verify expected elements are present in snapshot
6. Check interactive flows (click, fill, navigate) match expected behavior
7. `playwright-cli screenshot --filename=verify-{feature}.png` for evidence
8. `playwright-cli close`

## Tier 3 — Spec Override

If the spec file contains a `## Verification` section, parse it for:
- **Additional checks:** Lines starting with "Run `command`" → execute command, check exit code
- **Skip directives:** Lines starting with "Skip" → skip the named check
- **URL checks:** Lines with "Check ... returns" → curl/fetch the URL and verify response

Spec overrides take precedence over Tier 2 detection. They do NOT override Tier 1 (always-run).

## Plan Adherence Check

After all automated checks pass, review the implementation against the spec:

1. **Requirements coverage:** Read each requirement in the spec. For each, verify there is corresponding code AND a test. Track by priority level.
2. **Architecture match:** Compare the implementation's file structure and patterns against the spec's Architecture section.
3. **Acceptance criteria:** For each criterion, verify it is both implemented and tested.
4. **Scope check:** Look for code that doesn't map to any requirement (scope creep). Flag extra features.
5. **Out of scope respect:** Verify nothing in the Out of Scope section was implemented.

### Priority-Aware Adherence

- **P0 missing** → FAIL with failure_key `plan/requirement-missing:{requirement-slug}`
- **P1 missing** → Flag but don't FAIL (report as non-blocking)
- **P2 missing** → Note as observation (acceptable if cycles are running low)

## Failure Key Format

Every failure must be tagged with a structured key for stagnation detection.

Format: `tier{N}/{check}/{identifier}`

| Tier | Check | Key Example |
|------|-------|------------|
| 1 | typecheck | `tier1/typecheck/TS2345:src/payment.ts:42` |
| 1 | lint | `tier1/lint/no-unused-vars:src/old.ts:10` |
| 1 | test | `tier1/test/payment.test.ts:42` |
| 1 | build | `tier1/build/esbuild-error:src/index.ts` |
| 2 | playwright | `tier2/playwright/login-page-404` |
| 2 | cypress | `tier2/cypress/checkout-flow-timeout` |
| 3 | spec-check | `tier3/spec-check/api-returns-wrong-status` |
| plan | requirement | `plan/requirement-missing:rate-limiting` |
| plan | scope-creep | `plan/scope-creep:analytics-tracking` |

The orchestrator compares failure_key sets across verify attempts. Three identical
sets in a row = stagnation = abort. Be precise and consistent.

## Baseline Comparison

When baseline_failures are provided:
- Parse each baseline failure_key
- When running checks, compare every failure against the baseline
- **Match found** → ignore (pre-existing, not the builder's fault)
- **No match** → report as new failure
- **Baseline failure now passing** → note as bonus improvement (not required)

Use exact key matching. A baseline failure of `tier1/test/auth.test.ts:42` only
excuses that specific test at that specific line.

## Reporting Format

Mark verify tasks complete with structured metadata:

```json
{
  "verdict": "PASS",
  "failure_keys": [],
  "prognosis": null,
  "checks_run": "typecheck, lint, 47 tests, build, e2e, plan adherence",
  "baseline_excluded": 2
}
```

or

```json
{
  "verdict": "FAIL",
  "failure_keys": ["tier1/test/payment.test.ts:42", "plan/requirement-missing:rate-limiting"],
  "prognosis": "FIXABLE",
  "checks_run": "typecheck, lint, 45 tests (2 failed)",
  "baseline_excluded": 2
}
```

Send detailed findings to the builder using the format in `tim-verifier.md`.

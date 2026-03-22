# Tim Loop — Verification Strategy

Reference document for the verifier agent. Defines what to check and how.

## Two-Phase Verification Model

All verification follows a two-phase model:

```
Phase 1: GUARD CHECK (baseline invariants — must ALWAYS pass)
  ├── Spec Guards (from ## Guards section)
  ├── Or Standard Guards: typecheck + lint + existing tests + build
  └── If ANY guard fails → FAIL immediately, skip Phase 2

Phase 2: FEATURE VERIFICATION (new functionality — tracked with metric)
  ├── Tier 1: typecheck + lint + NEW tests + build (always run)
  ├── Tier 2: platform-detected checks (only if Tier 1 passes)
  ├── Tier 3: spec override checks (only if Tier 1 passes)
  ├── Plan adherence check
  └── Metric extraction (if metric_mode == "metric")
```

**Guard failures are non-negotiable.** They indicate a regression in existing
functionality. No amount of feature improvement can compensate for a guard failure.

## Baseline Mode

When running baseline verification (before builders make changes):
- Run all guard commands on the clean worktree — record failures as baseline
- Run Tier 1 checks — record any pre-existing failures
- If metric_mode == "metric": run Verify Command to capture baseline metric value
- Do NOT run Tier 2/3 (no changes to verify yet)
- Store results in task metadata: `{ baseline_failures: [...], baseline_metric: N }`

## Phase 1: Guard Check

Guards protect existing functionality. They are run from the spec's `## Guards` section.
If no Guards section exists, fall back to standard guards.

**Spec Guards:** Each line in `## Guards` is a command that must exit 0.
```bash
# Example spec guards:
npx tsc --noEmit                                    # typecheck
npm run lint                                         # lint
npm test -- --testPathIgnorePatterns="new-tests"     # existing tests only
npm run build                                        # build
```

**Standard Guards (fallback):** When no `## Guards` in spec:

```
┌──────────────┐  ┌──────────────┐
│  Typecheck   │  │    Lint       │   ← parallel
└──────┬───────┘  └──────┬───────┘
       │                 │
       └────────┬────────┘
                │
         ┌──────▼───────┐
         │ Existing Tests│   ← sequential (only if typecheck + lint pass)
         └──────┬───────┘
                │
         ┌──────▼───────┐
         │    Build      │   ← sequential (only if tests pass)
         └──────────────┘
```

**Guard failure keys use the `guard/` prefix:**
- `guard/typecheck/TS2345:src/payment.ts:42`
- `guard/lint/no-unused-vars:src/old.ts:10`
- `guard/test/existing-auth.test.ts:42`
- `guard/build/esbuild-error:src/index.ts`

**If any guard fails:** verdict = FAIL immediately. Do NOT run Phase 2.
The prognosis is usually FIXABLE (the builder broke something and needs to revert/fix).

## Phase 2: Feature Verification

Runs only after Phase 1 (guards) passes. Verifies NEW functionality.

### Tier 1 — Always Run (universal)

| Check | How to detect command | Example |
|-------|----------------------|---------|
| Type checking | `tsconfig.json` → `tsc --noEmit`; `Package.swift` → `swift build`; `*.py` → `mypy` or `pyright` if configured | `pnpm typecheck` or `tsc --noEmit` |
| Linting | `eslint.config.*` → `eslint`; `.swiftlint.yml` → `swiftlint`; `ruff.toml` → `ruff check` | `pnpm lint` |
| Unit tests | `vitest.config.*` → `vitest`; `jest.config.*` → `jest`; `*.xcodeproj` → `xcodebuild test`; `pytest.ini` → `pytest` | `pnpm test` |
| Build | `package.json` → `pnpm build`; `Makefile` → `make`; `*.xcodeproj` → `xcodebuild build` | `pnpm build` |

**Detection strategy:** Check the project root for config files. Use package.json scripts when available (`pnpm test`, `pnpm build`, `pnpm lint`, `pnpm typecheck`). Fall back to direct tool invocation.

**Monorepo handling:** If a monorepo root has workspace-level scripts (e.g., `pnpm test` runs all), use those. If a specific package was changed, also run `pnpm --filter <pkg> test` for targeted feedback.

**Note:** Tier 1 checks overlap with guards intentionally — guards run the EXISTING test
suite, Tier 1 runs the FULL suite (including new tests). If guards pass but Tier 1
finds new test failures, that's a feature issue, not a regression.

### Tier 2 — Platform Detection (agent-detected)

Check for these signals and run the corresponding verification. Only run checks relevant to files that changed.

| Signal | Verification Action | Notes |
|--------|-------------------|-------|
#### Automated E2E suites (run existing test suites)

| Signal | Verification Action | Notes |
|--------|-------------------|-------|
| `playwright` in package.json deps | `pnpm exec playwright test` or `npx playwright test` | Start dev server first if needed |
| `cypress` in package.json deps | `pnpm exec cypress run` | Start dev server first if needed |
| `.xcodeproj` or `Package.swift` present | `xcodebuild test -scheme <scheme> -destination 'platform=iOS Simulator,name=iPhone 16'` | Detect scheme from project |
| `vitest.config.e2e.ts` or `jest.config.e2e.ts` | Run E2E suite: `pnpm test:e2e` or equivalent | May need test infra (Docker, DB) |
| `docker-compose*.test.yml` present | `docker compose -f <file> up -d` before E2E, `down` after | Spin up test infra first |
| `*.swift` files changed | `swift test` or `xcodebuild test` | Run in package/project dir |
| Contract test files (`*.contract.test.*`) | Run contract test suite | Often separate config |
| `*.spec.ts` with `@playwright/test` import | `pnpm exec playwright test <file>` | Run specific spec files |
| Smoke test config (`vitest.config.smoke.*`) | Run smoke suite | May need running server |

#### Interactive browser verification (visual/manual checks)

When web UI changes are detected (e.g., `apps/web/`, `src/pages/`, `src/components/`
changed), run interactive browser verification for visual correctness.

**Tool selection priority** (use the first available):

1. **`/browse` (gstack)** — Preferred when gstack is installed. Fast headless browser
   with screenshot, interaction, diffing, and element assertion. Use the `/browse` skill.
2. **`playwright-cli`** — Fallback when gstack is not available. Superpowers headless
   browser with snapshot-based validation.
3. **`mcp__claude-in-chrome__*`** — Only if explicitly configured in the project's
   CLAUDE.md. Not used by default.

**Detection:** Check if gstack skills are available by looking for `~/.claude/skills/gstack/`.
If present, use `/browse`. Otherwise, check for `playwright-cli` skill at
`~/.claude/skills/playwright-cli/`. If neither is available, skip interactive browser
verification and note it in the verify report.

**When using `/browse` (gstack) for interactive browser verification:**
1. Start the dev server if not running
2. Navigate to affected pages
3. Take screenshots of each affected page/component
4. Verify expected elements are present and visually correct
5. Test interactive flows (click, fill, navigate) for correct behavior
6. Diff before/after states when applicable
7. Save screenshot evidence with descriptive filenames

**When using `playwright-cli` for interactive browser verification:**
1. Start the dev server if not running
2. `playwright-cli open http://localhost:<port>`
3. Navigate to pages affected by the change
4. `playwright-cli snapshot` to capture current state
5. Verify expected elements are present in snapshot
6. Check interactive flows (click, fill, navigate) match expected behavior
7. `playwright-cli screenshot --filename=verify-{feature}.png` for evidence
8. `playwright-cli close`

**Project CLAUDE.md overrides:** If the project's CLAUDE.md specifies a preferred browser
tool (e.g., "use /browse for all web browsing"), respect that directive regardless of
the priority order above.

### Tier 3 — Spec Override

If the spec file contains a `## Verification` section, parse it for:
- **Additional checks:** Lines starting with "Run `command`" → execute command, check exit code
- **Skip directives:** Lines starting with "Skip" → skip the named check
- **URL checks:** Lines with "Check ... returns" → curl/fetch the URL and verify response

Spec overrides take precedence over Tier 2 detection. They do NOT override guards or Tier 1.

### Metric Extraction

If metric_mode == "metric" and the spec has a `## Verify Command`:

1. Run the verify command
2. Parse the output for a single number
3. Compare to baseline_metric using the spec's Direction:
   - "higher is better": metric_delta = current - baseline (positive = improvement)
   - "lower is better": metric_delta = baseline - current (positive = improvement)
4. Include in metadata: `feature_metric`, `metric_delta`

### Plan Adherence Check

After all automated checks pass, review the implementation against the spec:

1. **Requirements coverage:** Read each requirement in the spec. For each, verify there is corresponding code AND a test. Track by priority level.
2. **Architecture match:** Compare the implementation's file structure and patterns against the spec's Architecture section.
3. **Acceptance criteria:** For each criterion, verify it is both implemented and tested.
4. **Scope check:** Look for code that doesn't map to any requirement (scope creep). Flag extra features.
5. **Out of scope respect:** Verify nothing in the Out of Scope section was implemented.

### Priority-Aware Adherence

- **P0 missing** → FAIL with failure_key `plan/requirement-missing:{requirement-slug}`
- **P1 missing** → Flag but don't FAIL (report as non-blocking)
- **P2 missing** → Note as observation (acceptable if iterations ran low)

## Feature Failure Key Format

Feature failures use the `tier{N}/` prefix:

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

## Baseline Comparison

When baseline_failures are provided:
- Parse each baseline failure_key
- When running checks, compare every failure against the baseline
- **Match found** → ignore (pre-existing, not the builder's fault)
- **No match** → report as new failure
- **Baseline failure now passing** → note as bonus improvement (not required)

Use exact key matching for lint and typecheck failures (line numbers are stable for
unchanged violations). For test failures, match by test name
(e.g. `tier1/test/auth.test.ts:should validate JWT`) rather than line number,
since line numbers shift when code changes.

## Reporting Format

Mark verify tasks complete with structured metadata:

```json
{
  "verdict": "PASS",
  "guard_status": "pass",
  "feature_metric": 85.1,
  "metric_delta": 12.8,
  "failure_keys": [],
  "prognosis": null,
  "checks_run": "guards (4/4 pass), typecheck, lint, 47 tests, build, e2e, plan adherence",
  "baseline_excluded": 2
}
```

or

```json
{
  "verdict": "FAIL",
  "guard_status": "fail",
  "feature_metric": null,
  "metric_delta": null,
  "failure_keys": ["guard/typecheck/TS2345:src/payment.ts:42"],
  "prognosis": "FIXABLE",
  "checks_run": "guards (1/4 fail — stopped at guard phase)",
  "baseline_excluded": 0
}
```

Send detailed findings to the builder using the format in `tim-verifier.md`.

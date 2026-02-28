# Tim Loop — Verification Strategy

Reference document for the verifier agent. Defines what to check and how.

## Tier 1 — Always Run (universal)

Run ALL of these in order. If any fail, stop and report.

| Check | How to detect command | Example |
|-------|----------------------|---------|
| Type checking | `tsconfig.json` -> `tsc --noEmit`; `Package.swift` -> `swift build`; `*.py` -> `mypy` or `pyright` if configured | `pnpm typecheck` or `tsc --noEmit` |
| Linting | `eslint.config.*` -> `eslint`; `.swiftlint.yml` -> `swiftlint`; `ruff.toml` -> `ruff check` | `pnpm lint` |
| Unit tests | `vitest.config.*` -> `vitest`; `jest.config.*` -> `jest`; `*.xcodeproj` -> `xcodebuild test`; `pytest.ini` -> `pytest` | `pnpm test` |
| Build | `package.json` -> `pnpm build`; `Makefile` -> `make`; `*.xcodeproj` -> `xcodebuild build` | `pnpm build` |

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
- **Additional checks:** Lines starting with "Run `command`" -> execute command, check exit code
- **Skip directives:** Lines starting with "Skip" -> skip the named check
- **URL checks:** Lines with "Check ... returns" -> curl/fetch the URL and verify response

Spec overrides take precedence over Tier 2 detection. They do NOT override Tier 1 (always-run).

## Plan Adherence Check

After all automated checks pass, review the implementation against the spec:

1. **Requirements coverage:** Read each requirement in the spec. For each, verify there is corresponding code AND a test.
2. **Architecture match:** Compare the implementation's file structure and patterns against the spec's Architecture section.
3. **Acceptance criteria:** For each criterion, verify it is both implemented and tested.
4. **Scope check:** Look for code that doesn't map to any requirement (scope creep). Flag extra features.
5. **Out of scope respect:** Verify nothing in the Out of Scope section was implemented.

## Reporting Format

Report results to the orchestrator as a one-line summary:

```
"PASS: All checks green (typecheck, lint, 47 tests, build, e2e, plan adherence)."
```

or

```
"FAIL: 2 blocking issues. Prognosis: FIXABLE. Details sent to builder."
```

Send detailed findings to the builder using this format:

```markdown
## Verify Attempt {N} Findings

### FAILURES
- tier/check file:line -- Description

### PLAN ADHERENCE
- requirement "X" -- Status: implemented/missing/partial
- scope creep: file:line -- Description (if any)

### PROGNOSIS
FIXABLE | NEEDS_HUMAN | UNCLEAR
Reasoning: ...
```

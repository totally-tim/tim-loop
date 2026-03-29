# Tim Loop — Verification Strategy

Reference document for the verifier agent. Defines what to check and how.

## Three-Phase Verification Model

All verification follows a three-phase model:

```
Phase 1: GUARD CHECK (baseline invariants — must ALWAYS pass)
  ├── Spec Guards (from ## Guards section)
  ├── Or Standard Guards: typecheck + lint + existing tests + build
  └── If ANY guard fails → FAIL immediately, skip Phase 2+3

Phase 2: FEATURE VERIFICATION (new functionality — tracked with metric)
  ├── Tier 1: typecheck + lint + NEW tests + build (always run)
  ├── Tier 2: platform-detected checks (only if Tier 1 passes)
  ├── Tier 3: spec override checks (only if Tier 1 passes)
  ├── Plan adherence check
  ├── Defensive review (input validation, security, atomicity, data consistency)
  └── Metric extraction (if metric_mode == "metric")
  └── If Phase 2 FAILs → skip Phase 3

Phase 3: INTEGRATION COMPLETENESS (top-down — does it work as a product?)
  ├── 3a. Stub/placeholder scan
  ├── 3b. Dead export / unreachable code detection
  ├── 3c. Connection verification (API↔UI, routes↔nav, components↔pages)
  └── 3d. User journey smoke tests (browser-based, from spec's ## User Journeys)
```

**Guard failures are non-negotiable.** They indicate a regression in existing
functionality. No amount of feature improvement can compensate for a guard failure.

**Phase 3 catches the "green tests, broken app" problem.** Code can pass every unit
test, typecheck, and lint check while being completely unreachable by users. Phase 3
verifies the feature works top-down, from the user's perspective.

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
- `guard/launch/crash-on-startup` (native apps only)

**Native App Launch Guard:**
For native desktop/mobile apps (macOS .app bundles, iOS, Android), add a launch guard
after the build guard. This catches the critical gap where an app compiles but crashes
on launch due to missing entitlements, sandbox conflicts, circular dependencies, or
runtime initialization errors (e.g., `EXC_BREAKPOINT` in `init()`).

```bash
# macOS example:
BUILD_DIR=$(xcodebuild -scheme MyApp -showBuildSettings 2>/dev/null | grep ' BUILT_PRODUCTS_DIR' | awk '{print $3}')
open -a "$BUILD_DIR/MyApp.app" &
APP_PID=$!
sleep 3
if ! pgrep -x "MyApp" > /dev/null 2>&1; then
  echo "GUARD FAIL: App crashed on launch"
  exit 1
fi
osascript -e 'quit app "MyApp"'
```

Detection: If the project has `*.xcodeproj`, `*.xcworkspace`, or Xcode build settings,
add the launch guard automatically. If the spec's `## Guards` section already includes
a launch guard, use that instead.

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

### Interactive Smoke Check (between Tier 2 and Tier 3)

After Tier 1 passes and Tier 2 completes, run a quick interactive smoke check on web
projects. This feeds into the `integration_coherence` quality score.

**Purpose:** Catch "green tests, broken app" problems earlier. This is NOT the full
user journey test (that's Phase 3d) — it's a fast preview that gives the builder
actionable feedback sooner.

**Process:**

1. **Detect dev server command:** Check verifier discovery, CLAUDE.md, or package.json
   scripts for `dev`, `start`, or `serve` commands.
2. **Start dev server** if not already running. Wait for it to be ready (check port).
3. **Navigate key routes** from the spec's `## Requirements`:
   - Home/landing page
   - Each page/route mentioned in requirements
   - Key feature entry points
4. **Screenshot critical states:**
   - Landing page
   - Feature-specific pages
   - Error states (if accessible)
5. **Check for problems:**
   - Pages render (not blank, not 500 error)
   - Navigation works (links/buttons lead to correct pages)
   - No console errors (check browser console output)
   - Key UI elements present (buttons, forms, data displays)
6. **Feed results into quality scores:**
   - All pages render + navigation works + no errors → high integration_coherence
   - Some pages fail → lower integration_coherence
   - Dev server won't start → log warning, score from static analysis only
7. **Save screenshots** as evidence with descriptive names (e.g., `smoke-{page-name}.png`)

**Tool selection:** Same priority as Tier 2 interactive verification:
1. `/browse` (gstack) — preferred
2. `playwright-cli` — fallback
3. Project CLAUDE.md overrides take precedence

**Timeout:** If the dev server hasn't become ready within 30 seconds, treat as "fails to start"
and fall back to static analysis scoring. Do not block indefinitely.

**Cleanup:** If you started the dev server for this smoke check, stop it when done.
The Phase 3d journey tests may start their own server — don't leave orphaned processes.

**Skip conditions:**
- No web UI in the feature (API-only, library, CLI) → skip entirely
- Dev server command not found → log warning, skip
- Dev server fails to start or times out → log warning, score from static analysis

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

After all automated checks pass, verify the implementation against the spec with structured,
per-requirement evidence. This is the primary defense against incomplete implementations.

**For each requirement in the spec's `## Requirements` section:**

1. Extract the requirement text and priority tag (`[P0]`/`[P1]`/`[P2]`)
2. Search the integration worktree for **implementation evidence:**
   - `grep -rn` for key identifiers that would exist if the requirement were implemented
     (function names, route paths, component names, class names, error strings, API endpoints)
   - If found: record `file:line` as `impl_evidence`
   - If NOT found: `impl_evidence = null`
3. Search test directories for **test evidence:**
   - `grep -rn` for test descriptions, assertions, or test function names covering the requirement
   - If found: record `file:line` as `test_evidence`
   - If NOT found: `test_evidence = null`
4. Determine status:
   - Both found → `"IMPLEMENTED"`
   - impl_evidence found, no test_evidence → `"IMPL_ONLY"`
   - Neither found → `"MISSING"`

**For each item in the spec's `## Acceptance Criteria` section:**
- Apply the same search-and-evidence process

**Build the `plan_adherence` array** and include it in task metadata:
```json
{
  "plan_adherence": [
    { "requirement": "[P0] Rate limiting on auth endpoints", "priority": "P0", "status": "IMPLEMENTED", "impl_evidence": "src/middleware/rateLimit.ts:15", "test_evidence": "tests/middleware/rateLimit.test.ts:8" },
    { "requirement": "[P0] JWT validation", "priority": "P0", "status": "MISSING", "impl_evidence": null, "test_evidence": null },
    { "requirement": "[P1] Error toast on failed login", "priority": "P1", "status": "IMPL_ONLY", "impl_evidence": "src/components/LoginForm.tsx:88", "test_evidence": null }
  ]
}
```

**Additional checks (after requirement evidence):**
1. **Architecture match:** Compare the implementation's file structure and patterns against the spec's Architecture section.
2. **Scope check:** Look for code that doesn't map to any requirement (scope creep). Flag extra features.
3. **Out of scope respect:** Verify nothing in the Out of Scope section was implemented.

### Priority-Aware Adherence

- **P0 `MISSING` or `IMPL_ONLY`** → FAIL with failure_key `plan/requirement-missing:{requirement-slug}`
- **P1 `MISSING`** → Flag but don't FAIL (report as non-blocking)
- **P2 `MISSING`** → Note as observation (acceptable if iterations ran low)

### Defensive Review (after plan adherence)

After plan adherence passes, review the implementation for robustness patterns the
spec doesn't explicitly test. This catches the class of issues that external code
review tools (GitHub AI review, etc.) typically find but internal loop agents miss.

**Scope:** Flag issues in new/modified code AND in existing code that is newly
reachable via data paths introduced by the change. Example: new code passes user
input to an existing CSV serializer that doesn't escape formula characters — flag
the serializer because the new data path makes it unsafe.

**Judgment rule:** Only flag patterns that create a user-visible failure mode.
Do not flag theoretical risks in code paths that are never reached with untrusted input.

**Four categories:**

#### 1. Input Validation (at API/system boundaries)

Check every new or modified endpoint, handler, or function that accepts external input:

- Are all user-supplied parameters validated before use?
- Are type conversions explicit (not relying on language coercion)?
- Are boundary values handled? (empty string, null, max length, negative numbers, zero)
- Are enum/set values validated against an allowed list?
- For PATCH/partial updates: are field existence checks in place?

Failure key: `defense/validation/{endpoint-or-function}:{issue}`

#### 2. Security Patterns

Check new code AND existing sinks reached via new data paths:

- **CSV/formula injection:** User data written to CSV cells starting with `=`, `+`, `-`, `@`, `\t`, `\r`
- **SQL injection:** String concatenation or template literals in SQL queries (vs parameterized)
- **XSS:** User input rendered in HTML without escaping or sanitization
- **Command injection:** User input interpolated into shell commands
- **Path traversal:** User input used in file paths without normalization/validation
- **Mass assignment:** Accepting all fields from request body without allowlist

Failure key: `defense/security/{pattern}:{file}:{line}`

#### 3. Atomicity & Error Handling

Check new code that performs multi-step mutations:

- Are multi-step database mutations wrapped in transactions?
- On partial failure, is state rolled back or left inconsistent? (orphaned records, half-created resources)
- Are error responses specific (not generic 500s with no context)?
- Are external API calls retried with backoff on transient failures?
- Are file operations atomic (write-to-temp-then-rename, not write-in-place)?

Failure key: `defense/atomicity/{operation}:{issue}`

#### 4. Data Consistency

Check for patterns that lead to divergent state:

- Are constants/configuration values defined in exactly one place? (no duplicate definitions across files)
- After a mutation, are caches or derived state invalidated?
- For concurrent access patterns, are race conditions handled? (optimistic locking, upserts, etc.)
- For partial updates: is the updated state consistent with invariants?

Failure key: `defense/consistency/{resource}:{issue}`

**Failure keys:** All defensive findings use the `defense/` prefix. The full taxonomy
(key formats, routing rules, severity levels) is defined in `tim-verifier.md` under
"Defensive review keys" — that is the single source of truth.

**Reporting:** Include defensive findings in the `failure_keys` array alongside
plan adherence and other Phase 2 findings. Route by file ownership (same as existing
keys). For cross-partition issues, route to the builder that introduced the new data path.

## Phase 3: Integration Completeness

Runs only after Phase 1 (guards) AND Phase 2 (feature verification) pass.
Phase 3 verifies the feature works as a product, not just as isolated code.

### 3a. Stub/Placeholder Scan

Scan the diff (new and modified files only) for incomplete implementations:

**Search patterns:**
- `TODO`, `FIXME`, `HACK`, `PLACEHOLDER`, `XXX` (case-insensitive)
- `NotImplementedError`, `throw new Error("not implemented")`
- `console.log("stub")`, `console.log("TODO")`
- Empty function/method bodies: functions that only contain `pass`, `return`, `return null`,
  `return undefined`, `return {}`, `return []`, or `throw`
- Hardcoded mock data: `"test"`, `"placeholder"`, `"TODO"`, `"example.com"` in non-test files
- Commented-out code blocks (lines starting with `//` or `#` that contain function calls or logic)

**Failure key format:** `integration/stub/{file}:{line}:{pattern}`

Examples:
- `integration/stub/src/api/invoices.ts:42:TODO`
- `integration/stub/src/components/InvoiceForm.tsx:15:empty-function`
- `integration/stub/src/services/payment.ts:28:hardcoded-mock`

**Severity:** Each stub is a BLOCKING failure. Stubs indicate incomplete work that will
break the feature at runtime even if all tests pass.

### 3b. Dead Export / Unreachable Code Detection

Check that new code is actually used — not just created:

**For each new file in the diff:**
1. Find all exports (named exports, default exports, module.exports)
2. Search the rest of the codebase for imports of those exports
3. If an export is never imported anywhere → dead export

**For web applications specifically:**
- New components: are they rendered in any page/layout? (`grep` for `<ComponentName` or `import ComponentName`)
- New pages/routes: are they registered in the router config?
- New API routes: are they registered in the server/router setup?
- New functions/hooks: are they called from any other module?

**Failure key format:** `integration/dead-export/{file}:{export-name}`

Examples:
- `integration/dead-export/src/components/InvoiceForm.tsx:InvoiceForm`
- `integration/dead-export/src/api/routes/invoices.ts:createInvoice`
- `integration/dead-export/src/hooks/useInvoice.ts:useInvoice`

**Severity:** Each dead export is a BLOCKING failure. An unreachable component or
function is a clear sign of incomplete integration.

### 3c. Connection Verification

Verify the seams between partitions are wired up. Use the architect's
`## Connections` map from the implementation contract as a checklist.

**For each connection in the contract:**

| Connection Type | What to verify | How |
|---|---|---|
| API endpoint → Frontend call | Frontend code contains a fetch/axios/trpc call to the endpoint URL | `grep` for the endpoint path in frontend files |
| Component → Page rendering | Component is imported and rendered in a page/layout file | `grep` for `<ComponentName` in page files |
| Route → Router config | Route path is registered in the router (Next.js `app/`, React Router, etc.) | Check router config for the path |
| Route → Navigation link | Route is linked from existing navigation (sidebar, menu, header) | `grep` for route path in nav components |
| Event handler → Event emitter | Handler is registered where events are dispatched | Check event registration code |
| Protocol → Concrete call | Protocol method is called with correct signature (arg count, types) | Read call site and protocol definition, verify match |
| Engine → AppState wiring | Engine references are stored and methods are called at startup | Read entry point init, verify engine.start()/setHandler() etc. |
| Notification → Observer | NotificationCenter.post matches addObserver name | `grep` for notification name in both poster and observer |
| Database migration → Model | New DB columns/tables have corresponding model definitions | Check ORM model files |
| Environment variable → Usage | New env vars referenced in code are documented in `.env.example` | Check `.env.example` or equivalent |

**Failure key format:** `integration/connection/{source}→{target}:{description}`

Examples:
- `integration/connection/POST /api/invoices→InvoiceForm:frontend-never-calls-endpoint`
- `integration/connection/InvoiceForm→/invoices/new:component-not-rendered-on-page`
- `integration/connection//invoices→sidebar:route-not-linked-in-navigation`

**Severity:** Each missing connection is a BLOCKING failure.

### 3d. User Journey Smoke Tests

If the spec has a `## User Journeys` section, execute each journey in a real browser.
This is the definitive integration test — it verifies the feature works from a user's
perspective, through actual navigation.

**Process:**

1. **Start the dev server** using the command from the spec's `## User Journeys` section
   (e.g., `npm run dev`). Wait for it to be ready.

2. **For each journey in the spec:**
   a. Open the app at the specified entry point (e.g., `http://localhost:3000`)
   b. Execute each step in sequence:
      - **Navigate steps:** Click the specified element, follow the navigation path
      - **Action steps:** Fill forms, click buttons, trigger the feature
      - **Checkpoint verification:** After each step, verify the checkpoint condition:
        - Element is visible/present
        - Page content matches expected state
        - URL is correct
        - Toast/notification appears
        - Data is displayed correctly
   c. Take a screenshot after each checkpoint as evidence
   d. If any checkpoint fails: record the failure and continue to the next journey

3. **For API-only journeys:** Execute the API call sequence using `curl` or equivalent,
   verifying response status codes and bodies at each checkpoint.

**Browser tool selection:** Same priority as Phase 2 interactive verification:
1. `/browse` (gstack) — preferred
2. `playwright-cli` — fallback
3. Project CLAUDE.md overrides take precedence

**Failure key format:** `integration/journey/{journey-name}:{step-number}:{description}`

Examples:
- `integration/journey/create-invoice:2:invoice-form-not-rendered`
- `integration/journey/create-invoice:3:submit-button-missing`
- `integration/journey/rate-limiting:2:expected-429-got-200`

**Evidence:** Each journey failure MUST include:
- Screenshot of the actual state at the failing checkpoint
- Expected state (from the spec's checkpoint description)
- URL at the time of failure
- Console errors (if any)

**Severity:** Each journey checkpoint failure is a BLOCKING failure. If a user can't
reach or use the feature through the expected path, the implementation is incomplete.

### 3e. Protocol/Interface Consistency Check

Verify that shared protocol/interface definitions match their concrete implementations
AND their call sites. This catches a critical class of integration failures where builders
implement a protocol method with the wrong signature, or where the app entry point calls
a method with arguments that don't match the protocol definition.

**Process:**

1. **Find shared contracts** from the architect's contract (`## Shared Contracts` section)
2. **For each protocol/interface in shared contracts:**
   a. Read the protocol definition — extract method signatures (name, params, return type)
   b. Find all concrete implementations (`grep` for class/struct conformance)
   c. Read each implementation — verify signature matches protocol exactly:
      - Same parameter count
      - Same parameter types (including optionality)
      - Same return type
      - Same isolation annotations (`@MainActor`, `nonisolated`, `async`)
   d. Find all call sites — verify they pass correct arguments:
      - Same argument count as protocol definition
      - Correct argument labels
3. **For notification-based connections** (common in macOS/iOS apps):
   a. Find all `NotificationCenter.default.post(name:)` calls
   b. For each, find the corresponding `addObserver(forName:)` call
   c. Verify the notification names match exactly (string comparison)
   d. Verify the observer is actually registered before the notification fires

**Failure key format:** `integration/protocol-mismatch/{protocol}:{method}:{description}`

Examples:
- `integration/protocol-mismatch/ActionExecuting:panicRestore:implementation-has-2-params-protocol-has-1`
- `integration/protocol-mismatch/RuleEvaluating:evaluate:impl-is-nonisolated-but-called-from-MainActor`
- `integration/protocol-mismatch/TriggerEngine:triggerManually:returns-Void-but-caller-expects-Bool`

**Why this matters:** In the LidLaunch v1 post-mortem, 5 protocol methods had signature
mismatches between the shared contracts and their implementations. The app compiled (each
partition compiled independently against the protocol) but failed at runtime because:
- `panicRestore(apps:)` was called with 1 arg but implemented with 2
- `triggerManually()` returned `Void` but the caller expected `Bool`
- `evaluate(context:)` was `nonisolated` in the protocol but `@MainActor` was needed
These are invisible to per-partition compilation but break at integration.

**Severity:** Each protocol mismatch is a BLOCKING failure.

### Phase 3 Skip Conditions

Phase 3 can be partially skipped when not applicable:
- **3a (stubs):** Always runs. No skip condition.
- **3b (dead exports):** Always runs. No skip condition.
- **3c (connections):** Skipped if the architect contract has no `## Connections` section
  (e.g., single-partition features with no cross-module wiring).
- **3d (user journeys):** Skipped if the spec has no `## User Journeys` section.
  The verifier should note "User journeys not defined — skipping smoke tests" in the report.
- **3e (protocol consistency):** Skipped if the architect contract has no `## Shared Contracts`
  section (single-partition features). Always runs for multi-partition builds.

## Failure Key Format (all phases)

| Phase | Prefix | Check | Key Example |
|-------|--------|-------|------------|
| Guard | `guard/` | typecheck | `guard/typecheck/TS2345:src/payment.ts:42` |
| Guard | `guard/` | test | `guard/test/existing-auth.test.ts:42` |
| Feature | `tier1/` | typecheck | `tier1/typecheck/TS2345:src/payment.ts:42` |
| Feature | `tier1/` | test | `tier1/test/payment.test.ts:42` |
| Feature | `tier1/` | build | `tier1/build/esbuild-error:src/index.ts` |
| Feature | `tier2/` | playwright | `tier2/playwright/login-page-404` |
| Feature | `tier3/` | spec-check | `tier3/spec-check/api-returns-wrong-status` |
| Feature | `plan/` | requirement | `plan/requirement-missing:rate-limiting` |
| Feature | `plan/` | scope-creep | `plan/scope-creep:analytics-tracking` |
| Integration | `integration/stub/` | stub | `integration/stub/src/api/invoices.ts:42:TODO` |
| Integration | `integration/dead-export/` | dead export | `integration/dead-export/src/components/Form.tsx:Form` |
| Integration | `integration/connection/` | connection | `integration/connection/POST /api/invoices→Form:not-called` |
| Integration | `integration/journey/` | journey | `integration/journey/create-invoice:2:form-not-rendered` |
| Integration | `integration/protocol-mismatch/` | protocol | `integration/protocol-mismatch/ActionExecuting:panicRestore:sig-mismatch` |
| Guard | `guard/launch/` | launch | `guard/launch/crash-on-startup` |

## Quality Scoring

After completing all phases, compute quality scores per the dimensions in
`tim-evaluation-calibration.md`. These scores are computed from verification results:

### Deriving Verifier Scores

| Dimension | Input | Scoring Method |
|---|---|---|
| **Functional completeness** | Plan adherence results | (P0 IMPLEMENTED count / total P0 count) * 10. If any P0 is MISSING, cap at 5. |
| **Code health** | Tier 1 results | Start at 10. Subtract 1 per typecheck error, 0.5 per lint warning, 1 per failing test. Floor at 1. |
| **Integration coherence** | Phase 3 results + smoke check | Start at 10. Subtract 2 per stub, 2 per dead export, 1 per missing connection, 3 per protocol mismatch. Add 1 if interactive smoke check passed. Add 1 if launch guard passed (native apps). Floor at 1. |

### Hard Threshold

No dimension below 6. If any dimension < 6, set verdict = FAIL regardless of
whether tests pass. Include the failing dimensions and rationale in the failure
feedback to builders.

Score 6 exactly = PASS (threshold is "below 6", not "at or below 6").

### Reporting Scores

Include `quality_scores` and `score_rationale` in task metadata alongside
existing fields (verdict, guard_status, feature_metric, etc.).

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
  "plan_adherence": [
    { "requirement": "[P0] Rate limiting", "priority": "P0", "status": "IMPLEMENTED", "impl_evidence": "src/middleware/rateLimit.ts:15", "test_evidence": "tests/middleware/rateLimit.test.ts:8" },
    { "requirement": "[P1] Error toast", "priority": "P1", "status": "IMPLEMENTED", "impl_evidence": "src/components/ErrorToast.tsx:22", "test_evidence": "tests/components/ErrorToast.test.tsx:10" }
  ],
  "integration_completeness": {
    "stubs_found": 0,
    "dead_exports_found": 0,
    "missing_connections": 0,
    "journeys_passed": 3,
    "journeys_total": 3
  },
  "failure_keys": [],
  "prognosis": null,
  "checks_run": "guards (4/4), feature (47 tests, build, e2e), adherence (5/5 P0, 3/3 P1), integration (0 stubs, 0 dead, 3/3 journeys)",
  "baseline_excluded": 2
}
```

or

```json
{
  "verdict": "FAIL",
  "guard_status": "pass",
  "feature_metric": 85.1,
  "metric_delta": 12.8,
  "plan_adherence": [
    { "requirement": "[P0] Rate limiting", "priority": "P0", "status": "IMPLEMENTED", "impl_evidence": "src/middleware/rateLimit.ts:15", "test_evidence": "tests/middleware/rateLimit.test.ts:8" },
    { "requirement": "[P0] JWT validation", "priority": "P0", "status": "MISSING", "impl_evidence": null, "test_evidence": null },
    { "requirement": "[P1] Error toast", "priority": "P1", "status": "IMPL_ONLY", "impl_evidence": "src/components/ErrorToast.tsx:22", "test_evidence": null }
  ],
  "integration_completeness": {
    "stubs_found": 2,
    "dead_exports_found": 1,
    "missing_connections": 1,
    "journeys_passed": 1,
    "journeys_total": 3,
    "journey_screenshots": ["verify-create-invoice-step2.png", "verify-create-invoice-step3.png"]
  },
  "failure_keys": [
    "plan/requirement-missing:jwt-validation",
    "integration/stub/src/api/invoices.ts:42:TODO",
    "integration/stub/src/services/email.ts:15:empty-function",
    "integration/dead-export/src/components/InvoiceForm.tsx:InvoiceForm",
    "integration/connection/POST /api/invoices→InvoiceForm:frontend-never-calls-endpoint",
    "integration/journey/create-invoice:2:invoice-form-not-rendered",
    "integration/journey/create-invoice:3:submit-returns-500"
  ],
  "prognosis": "FIXABLE",
  "checks_run": "guards (4/4), feature (47 tests, build), adherence (1/2 P0, 0/1 P1), integration (2 stubs, 1 dead, 1 conn, 1/3 journeys)",
  "baseline_excluded": 2
}
```

Send detailed findings to the builder using the format in `tim-verifier.md`.

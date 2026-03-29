# Post-Mortem Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement 9 improvements to tim-loop derived from a payroll feature post-mortem and CEO review with cross-model tension resolutions.

**Architecture:** All changes are edits to markdown prompt/instruction files that agents read at runtime. No runtime code. Changes span 6 files across the tim-loop skill: the orchestrator (SKILL.md), architect, builder, verifier, auditor, and verification strategy.

**Tech Stack:** Markdown prompt engineering. Git for version control.

**Source:** `~/.gstack/projects/totally-tim-tim-loop/ceo-plans/2026-03-29-post-mortem-improvements.md`

---

## File Structure

All modifications. No new files.

| File | Responsibility | Changes |
|------|---------------|---------|
| `skills/tim-loop/tim-architect.md` | Architect agent prompt + reference | Constants ownership Iron Law, schema validation format, HIGH complexity flag |
| `skills/tim-loop/tim-builder.md` | Builder agent prompt + reference | Subagent guidance for HIGH complexity partitions |
| `skills/tim-loop/tim-verify.md` | Verification strategy reference | Defensive review checklist (Phase 2 addition) |
| `skills/tim-loop/tim-verifier.md` | Verifier agent prompt + reference | Defensive failure key taxonomy, done-contract in plan adherence |
| `skills/tim-loop/tim-auditor.md` | Auditor agent prompt + reference | Subagent-powered audit process with adaptive threshold |
| `skills/tim-loop/SKILL.md` | Orchestrator pseudocode | Contract enforcement, typed message filtering, TSV timestamps, auditor subagent orchestration, done-contract wiring |
| `README.md` | Project documentation | Update key features and design principles |

---

### Task 1: Architect — Constants Ownership Iron Law + Schema Validation + Complexity Flag

**Files:**
- Modify: `skills/tim-loop/tim-architect.md`

This task adds three changes to the architect:
1. Iron Law: all shared constants/types MUST live in architect-owned contract files (prevents duplication like SURCHARGE_DEFAULTS)
2. Structured Decision/Rationale schema for partition sections (replaces free-form prose that led to 4-paragraph self-debate)
3. `complexity:` field in partition format so the orchestrator and builder know when to use subagents

- [ ] **Step 1: Add Iron Laws 12 and 13 to the architect spawn prompt**

In `tim-architect.md`, after Iron Law 11 ("Honor spike results..."), add:

```
    12. All shared constants, types, and configuration values MUST live in architect-owned contract files. No partition may define a constant that another partition also needs. If two partitions reference the same value, it belongs in shared contracts.
    13. One decision per topic in partition notes. Use the structured schema: Decision (one sentence), Rationale (one sentence), Cross-partition dependency (if any). Do not debate alternatives in prose.
```

- [ ] **Step 2: Add structured schema to the Implementation Contract Format**

In the `### Implementation Contract Format` section, update the partition template. After `**Isolation Notes:**` and its existing bullet points, replace `**Implementation Notes:**` with a structured format:

Replace:
```
**Implementation Notes:**
Brief guidance on approach, relevant existing code to reference, edge cases.
```

With:
```
**Implementation Notes:**
For each design decision in this partition, use the structured schema:

**Decision:** (one sentence — what the builder does)
**Rationale:** (one sentence — why this approach, not alternatives)
**Cross-partition dependency:** (if any — "Creates stubs in {path}. Reviewer replaces with real imports from partition M." If none, omit this line.)

Additional implementation guidance (existing code to reference, edge cases,
patterns to follow) can follow the structured decisions as free-form text.
```

- [ ] **Step 3: Add complexity field to partition format**

In the same partition template, after the `**iteration_budget:**` field, add:

```
**complexity:** {NORMAL | HIGH}
HIGH when this partition has more than 12 total requirements or touches more than
8 files across 3+ directories. When HIGH, the builder is advised to use subagents
for focused implementation chunks. The orchestrator includes this flag in the
builder's spawn prompt.
```

- [ ] **Step 4: Add complexity guidance to Builder Count Decision section**

In the `### Builder Count Decision` section, after the existing "Rules of thumb" list, add:

```
### Complexity Assessment

For each partition, assess complexity and set the `complexity` field:

- **NORMAL**: 1-12 requirements, concentrated in 1-2 directories. A single builder
  agent can hold the full context and implement sequentially.
- **HIGH**: 13+ requirements, OR touches 8+ files across 3+ directories, OR requires
  coordinating multiple subsystems (e.g., CRUD + state machine + export + admin).
  The builder will use sequential subagents for focused implementation chunks.

When flagging HIGH complexity, also increase the `iteration_budget` proportionally
(e.g., 10-12 iterations instead of the default 8).
```

- [ ] **Step 5: Commit**

```bash
git add skills/tim-loop/tim-architect.md
git commit -m "feat: architect constants ownership, schema validation, complexity flag

Add Iron Laws 12-13 for shared constants ownership and structured
decision schema. Add complexity field to partition format for builder
subagent guidance. Based on payroll post-mortem CEO review."
```

---

### Task 2: Builder — Subagent Guidance for HIGH Complexity Partitions

**Files:**
- Modify: `skills/tim-loop/tim-builder.md`

When the architect flags a partition as HIGH complexity, the builder dispatches sequential subagents for focused implementation chunks. The builder retains ownership of commits, guard checks, and keep/discard decisions.

- [ ] **Step 1: Add subagent section to the builder's Detailed Reference**

In `tim-builder.md`, after the `### Communication Protocol` section and before `### Git Discipline`, add a new section:

```markdown
### Subagent Mode (HIGH complexity partitions only)

When your partition is flagged `complexity: HIGH` by the architect, use subagents
to handle focused implementation chunks. This keeps your context window clean for
oversight while subagents handle the code writing.

**You remain the owner of the keep/discard loop.** Subagents write code; you commit,
verify, and decide keep/discard. A subagent NEVER commits or reverts.

**Process:**

1. **Plan the chunks:** Break your partition requirements into groups of 4-6 related
   requirements. Each group becomes one subagent's scope.

2. **For each chunk (sequential, not parallel):**
   a. Dispatch a subagent via the Agent tool:
      ```
      Agent tool (general-purpose):
        description: "Implement: {chunk description}"
        mode: "bypassPermissions"
        prompt: |
          You are a focused implementation subagent working in a builder's worktree.
          Worktree path: {BUILDER_WORKTREE}

          Implement ONLY these requirements:
          {chunk_requirements}

          Follow these conventions from the implementation contract:
          {relevant_conventions}

          Rules:
          - Write code and tests for the assigned requirements
          - Do NOT run git commands (no commit, no revert, no add)
          - Do NOT run guard checks or test suites
          - When done, report what you implemented and what files you changed
      ```
   b. When the subagent finishes, review its changes
   c. Stage, commit: `git add <files> && git commit -m "feat: {description}"`
   d. Run guard check (you, not the subagent)
   e. If guard FAILS: `git revert HEAD --no-edit` — try a different approach
   f. If guard PASSES: run metric check (if applicable), decide keep/discard
   g. Log the iteration result in task metadata

3. **Fallback:** If a subagent fails, times out, or produces unusable output,
   fall back to implementing the chunk yourself (direct mode). Log a warning
   in task metadata: `{ subagent_fallback: true, reason: "..." }`.

**When NOT to use subagents:**
- `complexity: NORMAL` partitions — just implement directly
- Remaining iterations < 3 — not enough budget for subagent overhead
- After a pivot decision — pivots need the builder's full context, not delegation

**Key invariant:** The keep/discard iteration diagram in the section above is
unchanged. Subagents are "hands" that write code — you are the brain that decides
whether to keep or discard each change.
```

- [ ] **Step 2: Add subagent note to swarm mode spawn prompt**

In the swarm mode spawn prompt template, after the `## Compiler Traps` section and before `## Iron Laws`, add:

```
    ## Partition Complexity

    Complexity: {PARTITION_COMPLEXITY}
    (If HIGH: use subagents for focused implementation chunks.
     Read the "Subagent Mode" section in tim-builder.md for the process.
     You own commits and keep/discard decisions. Subagents only write code.)
```

- [ ] **Step 3: Commit**

```bash
git add skills/tim-loop/tim-builder.md
git commit -m "feat: builder subagent guidance for HIGH complexity partitions

Builders can dispatch sequential subagents for complex partitions.
Builder retains commit/revert/keep-discard ownership. Subagents
only write code. Fallback to direct mode on subagent failure.
Based on payroll post-mortem CEO review."
```

---

### Task 3: Verification Strategy — Defensive Review Checklist

**Files:**
- Modify: `skills/tim-loop/tim-verify.md`

Add a defensive review phase to Phase 2 that catches security, validation, atomicity, and data consistency issues in new code and newly reachable existing code.

- [ ] **Step 1: Add Defensive Review section to Phase 2**

In `tim-verify.md`, after the `### Priority-Aware Adherence` section (around line 307) and before `## Phase 3: Integration Completeness`, add:

```markdown
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

**Reporting:** Include defensive findings in the `failure_keys` array alongside
plan adherence and other Phase 2 findings. Defensive findings use the `defense/`
prefix and route by file ownership (same as existing keys). For cross-partition
issues, route to the builder that introduced the new data path.

**Severity:** Defensive findings are BLOCKING for security patterns (category 2)
and atomicity issues that leave state inconsistent (category 3, partial failure
without rollback). Input validation (category 1) and data consistency (category 4)
findings are NON-BLOCKING unless they create a clear data loss or corruption path.
```

- [ ] **Step 2: Update the Phase 2 flow diagram**

In the three-phase verification model at the top of tim-verify.md, update the Phase 2 section:

Replace:
```
Phase 2: FEATURE VERIFICATION (new functionality — tracked with metric)
  ├── Tier 1: typecheck + lint + NEW tests + build (always run)
  ├── Tier 2: platform-detected checks (only if Tier 1 passes)
  ├── Tier 3: spec override checks (only if Tier 1 passes)
  ├── Plan adherence check
  └── Metric extraction (if metric_mode == "metric")
  └── If Phase 2 FAILs → skip Phase 3
```

With:
```
Phase 2: FEATURE VERIFICATION (new functionality — tracked with metric)
  ├── Tier 1: typecheck + lint + NEW tests + build (always run)
  ├── Tier 2: platform-detected checks (only if Tier 1 passes)
  ├── Tier 3: spec override checks (only if Tier 1 passes)
  ├── Plan adherence check
  ├── Defensive review (input validation, security, atomicity, data consistency)
  └── Metric extraction (if metric_mode == "metric")
  └── If Phase 2 FAILs → skip Phase 3
```

- [ ] **Step 3: Commit**

```bash
git add skills/tim-loop/tim-verify.md
git commit -m "feat: defensive review checklist in Phase 2 verification

Four categories: input validation, security patterns, atomicity/error
handling, data consistency. Scoped to new code + new data paths to
existing sinks. Security and atomicity findings are BLOCKING.
Based on payroll post-mortem CEO review."
```

---

### Task 4: Verifier — Defensive Failure Key Taxonomy + Done-Contract Adherence

**Files:**
- Modify: `skills/tim-loop/tim-verifier.md`

Add the defensive failure key prefixes and update plan adherence to check done-contracts.

- [ ] **Step 1: Add defensive failure keys to the Failure Keys section**

In `tim-verifier.md`, in the `### Failure Keys` section (around line 176), after the existing examples, add:

```markdown

**Defensive review keys use the `defense/` prefix:**
- `defense/validation/POST-api-invoices:missing-amount-check`
- `defense/security/csv-injection:src/export/csv.ts:42`
- `defense/security/sql-injection:src/db/queries.ts:15`
- `defense/atomicity/create-payroll-run:no-transaction-rollback`
- `defense/consistency/surcharge-defaults:duplicated-in-two-files`

Defensive findings route by file ownership (same as other failure keys).
For cross-partition issues, route to the builder that introduced the new data path.
Security (defense/security/*) and atomicity partial-failure (defense/atomicity/*) findings
are BLOCKING. Input validation and data consistency findings are NON-BLOCKING unless
they create a clear data loss or corruption path.
```

- [ ] **Step 2: Update plan adherence to include done-contract verification**

In the `### Communication Protocol` section, in the integration verification metadata example (the `plan_adherence` array), add a note after the array:

After the `plan_adherence` array in the PASS metadata example, add:

```
    done_contract_adherence: [
      { builder: "builder-1", committed: "POST /api/invoices returns 201 with invoice object", status: "DELIVERED", evidence: "src/api/invoices.ts:42" },
      { builder: "builder-1", committed: "Tests cover happy path + 2 error cases", status: "DELIVERED", evidence: "tests/api/invoices.test.ts:8" }
    ],
```

And in the FAIL metadata example, add a corresponding section showing a gap:

```
    done_contract_adherence: [
      { builder: "builder-3", committed: "Call calculateCompensation() per employee", status: "NOT_DELIVERED", evidence: "imported but never called in POST handler" }
    ],
```

- [ ] **Step 3: Add done-contract section to the Plan Adherence Check description**

In the Mode 2 (Integration Verification) section, after the "Plan adherence check" line and before "Metric extraction", add a note:

After `- Plan adherence check` add:
```
  - Done-contract adherence check (if contract negotiation ran: verify each builder
    delivered what they committed to in their done-contract, not just the spec)
```

- [ ] **Step 4: Commit**

```bash
git add skills/tim-loop/tim-verifier.md
git commit -m "feat: defensive failure key taxonomy + done-contract adherence

Add defense/* failure key prefixes for input validation, security,
atomicity, and data consistency. Add done-contract adherence check
to plan adherence verification. Based on payroll post-mortem CEO review."
```

---

### Task 5: Auditor — Subagent-Powered Audit Process

**Files:**
- Modify: `skills/tim-loop/tim-auditor.md`

Add adaptive subagent dispatch: when total requirements exceed 15, the auditor dispatches subagents (one per partition) for parallel deep-reading, then synthesizes results and runs cross-partition checks itself.

- [ ] **Step 1: Add Adaptive Audit Mode section to the Detailed Reference**

In `tim-auditor.md`, after the `### Deep Audit Process` section (after Step 6 — Determine per-requirement verdict), add:

```markdown
### Adaptive Audit Mode

When total requirements (requirements + acceptance criteria) exceed 15, use
subagent dispatch for parallel deep-reading. Below 15, audit directly (existing process above).

**Subagent dispatch process:**

1. **Count total requirements.** Include both `## Requirements` and `## Acceptance Criteria`.
   If total <= 15, skip this section — audit directly using the Deep Audit Process above.

2. **Group by partition.** Using the architect contract's `## Partitions` section,
   assign each requirement to its owning partition.

3. **Dispatch one subagent per partition:**
   ```
   Agent tool (general-purpose):
     description: "Audit partition: {partition_name}"
     mode: "bypassPermissions"
     prompt: |
       You are an audit subagent. Read source files in the integration worktree
       and classify implementations and tests for the assigned requirements.

       Integration worktree: {INTEGRATION_WORKTREE}

       ## Requirements to Audit
       {partition_requirements}

       ## Classification Rubric

       For each requirement:
       1. Grep for implementation (function names, route paths, component names)
       2. Read the source file. Classify:
          - REAL: Contains actual business logic (conditionals, transforms, API calls, error handling)
          - STUB: Empty body, TODO, hardcoded mock, delegates to unimplemented function
          - MISSING: Not found after multiple search terms
       3. Grep for tests. Read the test file. Classify:
          - THOROUGH: Tests assert meaningful behavior, multiple assertions, happy + error paths
          - SHALLOW: Only checks existence/truthiness, mocks everything, happy path only
          - MISSING: No test found
       4. For each, provide: impl_file, impl_snippet (2-3 lines), test_file, test_assessment

       Report structured results as your final output — one entry per requirement.
   ```

4. **Wait for all subagents.** Collect results.

5. **Handle failures:** If any subagent fails or times out, fall back to auditing
   that partition's requirements directly (using the Deep Audit Process above).
   Log: `{ subagent_fallback: true, partition: "{name}", reason: "..." }`.

6. **Synthesize:** Merge all subagent results into a unified `deep_audit` array.
   Validate each entry: if a subagent classified something as REAL but the snippet
   looks like a stub (TODO, empty body, pass-through), override to STUB.

7. **Run cross-partition checks yourself (do NOT delegate these):**
   - Contract Usage Verification (are shared types imported by consumers?)
   - Entry-Point Reachability Tracing (is the feature reachable from the app entry?)
   - App Entry Point Wiring Audit (for multi-partition builds)
   - Connection Audit (are cross-partition seams wired per the connections map?)

8. **Score and report** using the same metadata format as the direct audit process.

**Why cross-partition checks stay centralized:** Subagents audit requirements within
partition boundaries. Cross-partition integration (wiring, reachability, contract usage)
requires seeing across partition boundaries — only the auditor has the full picture.
```

- [ ] **Step 2: Add Iron Law 11 about subagent fallback**

In the auditor's Iron Laws (spawn prompt), after Iron Law 10, add:

```
    11. When using subagents (>15 requirements): you own cross-partition checks. Subagents handle per-partition deep reads. If a subagent fails, fall back to direct audit for that partition.
```

- [ ] **Step 3: Commit**

```bash
git add skills/tim-loop/tim-auditor.md
git commit -m "feat: subagent-powered auditor with adaptive threshold

When requirements exceed 15, auditor dispatches per-partition subagents
for parallel deep-reading. Cross-partition checks (wiring, reachability,
contract usage) stay centralized. Fallback to direct on subagent failure.
Based on payroll post-mortem CEO review."
```

---

### Task 6: Orchestrator — Contract Enforcement + Done-Contract Wiring

**Files:**
- Modify: `skills/tim-loop/SKILL.md`

Make contract negotiation mandatory (remove the cycle-1-only conditional) and wire done-contracts into build tasks, verification, resume state, and agent refresh.

- [ ] **Step 1: Make contract negotiation non-optional**

In `SKILL.md`, in THE LOOP section, replace:

```
  ## 0.5. CONTRACT NEGOTIATION (cycle 1 only)
  if outer_cycle == 1:
    Tell user: "Cycle 1: Negotiating done-contracts with builders..."
```

With:

```
  ## 0.5. CONTRACT NEGOTIATION (mandatory on cycle 1)
  if outer_cycle == 1:
    Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Negotiating done-contracts with builders..."
```

- [ ] **Step 2: Persist done-contracts after negotiation**

After the existing line `Log warning: "Contract not fully approved, proceeding with builder's latest proposal."`, add:

```

    ## Persist done-contracts for downstream use
    done_contracts = {}
    for each partition:
      done_contracts[partition.builder_name] = builder_contract_from_metadata
    ## done_contracts are passed to build tasks, verification, resume, and refresh
```

- [ ] **Step 3: Wire done-contracts into build tasks**

In the BUILD section's TaskCreate, after the line `Your requirements: {partition.requirements}`, add:

```
      Your done-contract (what you committed to deliver):
      {done_contracts[partition.builder_name] or "No done-contract (cycle 2+ or negotiation skipped)"}
```

- [ ] **Step 4: Wire done-contracts into verification**

In the VERIFY INTEGRATION section's TaskCreate, after `Baseline metric: {baseline_metric}`, add:

```

      Done-contracts (verify builders delivered what they committed to):
      {done_contracts or "None (negotiation did not run)"}
      If done-contracts are present, include done_contract_adherence in metadata:
      For each builder's done-contract, check whether each committed item was delivered.
```

- [ ] **Step 5: Wire done-contracts into resume state**

In the ABORT Procedure's `.tim-loop-resume.json` schema, after `"latest_metric": 85.1,`, add:

```
       "done_contracts": {
         "builder-1": "## Builder-1 Done Contract\n### Will Build\n...",
         "builder-2": "## Builder-2 Done Contract\n..."
       },
```

- [ ] **Step 6: Wire done-contracts into REFRESH_AGENTS**

In the REFRESH_AGENTS procedure signature, add `done_contracts` parameter:

Replace:
```
REFRESH_AGENTS(cycle_number, reviewer_findings_by_builder, pr_number, baseline, partitions, contract_content, verifier_discovery):
```

With:
```
REFRESH_AGENTS(cycle_number, reviewer_findings_by_builder, pr_number, baseline, partitions, contract_content, verifier_discovery, done_contracts):
```

And in step 5 (Spawn fresh builders), after `{PREVIOUS_FINDINGS_OR_EMPTY}`, add:

```
      - {DONE_CONTRACT} = done_contracts[partition.builder_name] or "None"
```

- [ ] **Step 7: Commit**

```bash
git add skills/tim-loop/SKILL.md
git commit -m "feat: mandatory contract negotiation + done-contract wiring

Contract negotiation is now mandatory on cycle 1 (was skippable).
Done-contracts are persisted and wired into build tasks, verification,
resume state, and agent refresh. Verifier checks delivery against
done-contracts, not just spec. Based on payroll post-mortem CEO review."
```

---

### Task 7: Orchestrator — Typed Message Filtering

**Files:**
- Modify: `skills/tim-loop/SKILL.md`

Add orchestrator Iron Law for typed message filtering: suppress idle messages from completed builders, always process escalation-type messages.

- [ ] **Step 1: Add Iron Law 11 to Orchestrator Iron Laws**

In `SKILL.md`, after Iron Law 10 ("Log everything to TSV..."), add:

```
11. **Typed message filtering.** After a builder's build task is completed, suppress status/progress/idle messages from that builder. ALWAYS process escalation messages (prefixed QUESTION:, NEEDS_HUMAN:, SCOPE_CONFLICT:, CONTRACT_ISSUE:) regardless of task status. Builders remain alive — if integration fails, assign a fix task to the existing builder.
```

- [ ] **Step 2: Commit**

```bash
git add skills/tim-loop/SKILL.md
git commit -m "feat: typed message filtering for completed builders

Orchestrator suppresses idle messages from completed builders but
always processes escalation-prefixed messages (QUESTION, NEEDS_HUMAN,
SCOPE_CONFLICT, CONTRACT_ISSUE). No builder shutdown/spawn cycling.
Based on payroll post-mortem CEO review."
```

---

### Task 8: Orchestrator — TSV Wall-Clock Timestamps

**Files:**
- Modify: `skills/tim-loop/SKILL.md`

Add `start_ts` and `end_ts` columns to the TSV progress log format.

- [ ] **Step 1: Update TSV format definition**

In the `## TSV Progress Log` section, replace the format block:

Replace:
```
Format:
```
cycle	phase	builder	iteration	metric	guard	status	duration_s	description
0	BASELINE	-	0	72.3	pass	baseline	5	initial state
1	CONTRACT	-	0	null	pass	complete	45	contract negotiation
1	BUILD	builder-1	1	75.0	pass	keep	30	implemented auth endpoints
1	BUILD	builder-1	2	75.0	fail	revert	25	broke existing tests
1	BUILD	builder-1	3	78.2	pass	keep	35	auth endpoints with fixed imports
1	BUILD	builder-2	1	72.3	pass	keep	28	added UI components
1	BUILD	builder-2	2	72.3	pass	discard	22	metric unchanged after refactor
1	VERIFY	integration	0	80.5	pass	PASS	60	integrated verify
1	REVIEW	review	0	80.5	pass	PASS	120	review approved
```
```

With:

```
Format:
```
cycle	phase	builder	iteration	metric	guard	status	duration_s	start_ts	end_ts	description
0	BASELINE	-	0	72.3	pass	baseline	5	2026-03-29T14:00:00Z	2026-03-29T14:00:05Z	initial state
1	CONTRACT	-	0	null	pass	complete	45	2026-03-29T14:00:05Z	2026-03-29T14:00:50Z	contract negotiation
1	BUILD	builder-1	1	75.0	pass	keep	30	2026-03-29T14:00:50Z	2026-03-29T14:01:20Z	implemented auth endpoints
1	BUILD	builder-1	2	75.0	fail	revert	25	2026-03-29T14:01:20Z	2026-03-29T14:01:45Z	broke existing tests
1	VERIFY	integration	0	80.5	pass	PASS	60	2026-03-29T14:05:00Z	2026-03-29T14:06:00Z	integrated verify
1	REVIEW	review	0	80.5	pass	PASS	120	2026-03-29T14:06:00Z	2026-03-29T14:08:00Z	review approved
```

The `start_ts` and `end_ts` columns use ISO 8601 UTC format. The orchestrator
captures `start_ts` by running `date -u +%Y-%m-%dT%H:%M:%SZ` before dispatching
each phase task and `end_ts` after reading the completed task metadata.
```

- [ ] **Step 2: Update all append_tsv_row calls**

Find every `append_tsv_row(` call in SKILL.md and add `start_ts, end_ts` parameters. There are 4 occurrences:

1. Contract negotiation: `append_tsv_row(outer_cycle, "CONTRACT", "-", 0, null, "pass", "complete", duration_s, "contract negotiation")`
   → add `start_ts, end_ts` before `"contract negotiation"`

2. Build iterations (logged from task metadata, not direct calls) — no change needed, the builder logs iterations in task metadata

3. Verify integration: `append_tsv_row(outer_cycle, "VERIFY", "integration", 0, feature_metric, guard_status, verdict, duration_s, "integrated verify")`
   → add `start_ts, end_ts` before `"integrated verify"`

4. Review: `append_tsv_row(outer_cycle, "REVIEW", "review", 0, feature_metric, "pass", "PASS", duration_s, "review approved")`
   → add `start_ts, end_ts` before `"review approved"`

Also update the baseline row initialization in Step 6:

Replace:
```
cycle\tphase\tbuilder\titeration\tmetric\tguard\tstatus\tduration_s\tdescription
0\tBASELINE\t-\t0\t{baseline_metric}\tpass\tbaseline\t{duration}\tinitial state
```

With:
```
cycle\tphase\tbuilder\titeration\tmetric\tguard\tstatus\tduration_s\tstart_ts\tend_ts\tdescription
0\tBASELINE\t-\t0\t{baseline_metric}\tpass\tbaseline\t{duration}\t{start_ts}\t{end_ts}\tinitial state
```

- [ ] **Step 3: Commit**

```bash
git add skills/tim-loop/SKILL.md
git commit -m "feat: TSV wall-clock timestamps for phase bottleneck analysis

Add start_ts and end_ts columns (ISO 8601 UTC) to TSV progress log.
Orchestrator captures timestamps before dispatching and after completing
each phase task. Enables identifying which phases are bottlenecks.
Based on payroll post-mortem CEO review."
```

---

### Task 9: Orchestrator — Auditor Subagent Orchestration in Step 5

**Files:**
- Modify: `skills/tim-loop/SKILL.md`

Update Step 5 (REVIEW) to pass requirement count context to the auditor so it can decide whether to use subagents, and include partition assignments in the auditor task description.

- [ ] **Step 1: Update auditor task description in Step 5**

In the REVIEW section's auditor TaskCreate, after `## User Journeys`, add:

```

      ## Partition Assignments (for subagent dispatch if requirements > 15)

      {PARTITION_ASSIGNMENTS}
      (Format: partition name → builder name → requirement list. The auditor uses
      this to group requirements by partition when dispatching subagents.)

      Total requirements: {TOTAL_REQUIREMENT_COUNT}
      (If > 15: use Adaptive Audit Mode with per-partition subagents.
       If <= 15: audit directly without subagents.)
```

- [ ] **Step 2: Add partition assignment extraction to orchestrator**

In the orchestrator pseudocode, after reading the approved contract (Step 5b, item 4), where partitions are extracted, add a note:

After `- partition_count — number of partitions`, add:
```
   - partition_assignments — formatted string mapping each partition to its requirements (for auditor subagent dispatch)
   - total_requirement_count — count of all requirements + acceptance criteria (for auditor adaptive threshold)
```

- [ ] **Step 3: Commit**

```bash
git add skills/tim-loop/SKILL.md
git commit -m "feat: pass partition assignments to auditor for subagent dispatch

Auditor receives partition-to-requirement mapping and total count so
it can decide whether to use Adaptive Audit Mode (subagents for >15
requirements). Based on payroll post-mortem CEO review."
```

---

### Task 10: Update README

**Files:**
- Modify: `README.md`

Update the key features and design principles to reflect the new capabilities.

- [ ] **Step 1: Add new key features**

In the `## Key Features` section, after the existing bullet list, add these new entries:

```
- **Defensive review** — Phase 2 verification includes a 4-category defensive review: input validation at API boundaries, security patterns (CSV injection, SQL injection, XSS, command injection, path traversal), atomicity/error handling (transactions, rollback), and data consistency. Scoped to new code plus new data paths to existing sinks. Catches the class of issues that external AI code review finds but per-file testing misses.
- **Typed message filtering** — Orchestrator suppresses idle messages from completed builders but always processes escalation-prefixed messages (QUESTION, NEEDS_HUMAN, SCOPE_CONFLICT, CONTRACT_ISSUE). No builder shutdown/spawn cycling — builders stay alive for potential fix routing.
- **Architect schema validation** — Partition implementation notes use a structured Decision/Rationale/Cross-partition-dependency schema. Forces clarity without stripping technical detail. Prevents the "four paragraphs debating isolation strategy" anti-pattern.
- **Mandatory contract negotiation** — Contract negotiation (Step 0.5) is mandatory on cycle 1. Done-contracts are wired into build tasks and verification — the verifier checks "did the builder deliver what they committed to?" not just "does the code match the spec?"
- **Builder subagent mode** — For HIGH complexity partitions (13+ requirements or 8+ files across 3+ directories), builders dispatch sequential subagents for focused implementation chunks. Builder retains commit/revert/keep-discard ownership. Subagents only write code.
- **Subagent-powered auditor** — When total requirements exceed 15, the auditor dispatches per-partition subagents for parallel deep-reading. Cross-partition checks (wiring, reachability, contract usage) stay centralized. Fallback to direct mode on subagent failure.
- **TSV wall-clock timestamps** — `start_ts` and `end_ts` columns (ISO 8601 UTC) on every TSV row enable phase-level bottleneck identification.
- **Constants ownership** — Iron Law: all shared constants and types must live in architect-owned contract files. No partition may define a constant another partition also needs. Prevents the duplicated-constants class of integration bugs.
```

- [ ] **Step 2: Add design principle**

In the `## Design Principles` section, after the last principle, add:

```
**Defense in depth, not just existence checking** — The loop verifies three things independently: does the feature exist (plan adherence), is the feature robust (defensive review), and is the feature reachable (integration completeness). External code review tools consistently found security and atomicity issues that per-file testing missed. The defensive review checklist catches these inside the loop.

**Subagents for scale, not for decomposition** — When agents hit context or complexity limits, they dispatch subagents for grunt work (searching, reading, implementing chunks) while retaining ownership of judgment calls (keep/discard, scoring, cross-partition checks). The parent agent orchestrates; subagents are hands, not brains.
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: update README with post-mortem improvement features

Add defensive review, typed message filtering, schema validation,
mandatory contract negotiation, builder/auditor subagent modes,
TSV timestamps, and constants ownership to key features and design
principles. Based on payroll post-mortem CEO review."
```

---

## Self-Review

**Spec coverage check against CEO plan:**
- Item 1 (Contract enforcement + wiring): Task 6 (SKILL.md) + Task 4 (verifier done-contract)
- Item 2 (Builder subagents): Task 2 (builder) + Task 1 step 3-4 (architect complexity flag)
- Item 3 (Constants ownership): Task 1 step 1 (architect Iron Law 12)
- Item 4 (Message filtering): Task 7 (orchestrator Iron Law 11)
- Item 5 (Defensive review): Task 3 (tim-verify.md)
- Item 6 (Failure key taxonomy): Task 4 step 1 (verifier defense/* keys)
- Item 7 (Schema validation): Task 1 step 2 (architect structured format)
- Item 8 (Subagent auditor): Task 5 (auditor) + Task 9 (orchestrator partition assignments)
- Item 9 (TSV timestamps): Task 8 (SKILL.md)
All 9 items covered.

**Placeholder scan:** No TBD/TODO/fill-in-later patterns found.

**Type consistency:** Failure key prefixes consistent across tim-verify.md and tim-verifier.md (`defense/validation/*`, `defense/security/*`, `defense/atomicity/*`, `defense/consistency/*`). Done-contract metadata field names consistent between SKILL.md (`done_contracts`), tim-verifier.md (`done_contract_adherence`), and resume state. Complexity field (`NORMAL | HIGH`) consistent between architect and builder.

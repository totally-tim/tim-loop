---
name: tim-loop
description: Use when you have a feature spec and want to automatically build, verify, and review it in an isolated worktree with a multi-agent team
effort: max
---

# Tim Loop — Automated Build-Verify-Review Loop

**Announce at start:** "I'm using the Tim Loop skill to run the automated build-verify-review loop."

## Overview

Tim Loop takes a feature spec (.md file) and runs an automated development loop:
1. Creates isolated git worktrees — one integration branch + one per builder
2. Spawns a multi-agent team: architect (planning), N builders (parallel, isolated), verifier, reviewer (integrator)
3. Uses a shared task list for coordination — agents claim tasks, mark progress, and the user sees real-time status via `Ctrl+T`
4. Builders work in isolation with autoresearch-style keep/discard iteration (atomic commits, metric-driven decisions)
5. Reviewer merges builder branches into the integration branch, runs integration verification, and reviews the PR
6. Ends with a PR ready for human review (or an abort with resume state)

You (the orchestrator) are a **thin coordinator**. You create tasks, assign them,
monitor task status, and make decisions. You NEVER read source files,
run tests, analyze diffs, or generate fix suggestions. Agents do all real work.

## Defaults (overridable via spec's `## Loop Config`)

| Setting | Default | Spec Override Key |
|---------|---------|-------------------|
| MAX_OUTER_CYCLES | 3 | `max_outer_cycles` |
| MAX_BUILDER_ITERATIONS | 8 | `max_builder_iterations` |
| REQUIRE_PLAN_APPROVAL | true (cycle 1 only) | `require_plan_approval` |
| SKIP_BASELINE | false | `skip_baseline` |
| BUILDER_COUNT | auto | `builder_count` |
| MAX_BUILDERS | 5 | `max_builders` |
| METRIC_MODE | auto | `metric_mode` |

`builder_count: auto` means the architect agent decides based on codebase analysis.
Set to an integer to force a specific number of builders.
`max_builders` caps the architect's recommendation (safety valve for token costs).
`METRIC_MODE: auto` means: use metric-driven keep/discard if the spec has a `## Metric` section; fall back to pass/fail if not.

## SETUP Phase

### Step 1: Load and Validate Spec

Read the spec file passed as argument. Validate it has:
- `## Goal` (non-empty)
- `## Requirements` (at least one item, each with a priority tag `[P0]`/`[P1]`/`[P2]`)
- `## Acceptance Criteria` (at least one item)

If validation fails, tell the user what's missing and stop.

Extract these optional sections:
- `## Verification` — spec overrides for the verifier
- `## Loop Config` — overrides for loop constants (parse `key: value` lines)
- `## Risk Assessment` — blast radius and risk level
- `## Test Strategy` — test types, fixtures, mocks
- `## Open Questions` — unknowns the builder should investigate early
- `## Metric` — mechanical metric command, direction, baseline value
- `## Guards` — baseline invariant commands (must exit 0)
- `## Verify Command` — shell command to extract metric value
- `## User Journeys` — end-to-end browser/API flows for integration smoke tests
- `## Spike Tasks` — pre-loop verification experiments for hardware/undocumented APIs
- `## Compiler Traps` — language-specific patterns that waste builder iterations

If requirements lack priority tags, warn the user and default all to `[P0]`.

Determine `metric_mode`:
- If spec has `## Metric` AND `## Verify Command`: `metric_mode = "metric"`
- Else: `metric_mode = "pass_fail"` (legacy behavior)

Extract the feature name from the `# Feature:` heading for use as team name slug.
Slugify: lowercase, replace spaces with hyphens, remove special characters.

### Step 2: Create Worktrees

Create an **integration worktree** — this is the central branch where all work merges.

```bash
# Create integration worktree
git worktree add <worktree-base>/integration -b tim-loop/{feature-slug}/integration

# Exclude tim-loop artifacts from git tracking
# IMPORTANT: In a worktree, .git is a FILE (not a directory) containing "gitdir: <path>".
# We must resolve the actual gitdir path to find info/exclude.
WORKTREE_GITDIR=$(sed 's/^gitdir: //' < <integration-worktree>/.git)
mkdir -p "$WORKTREE_GITDIR/info"
echo '.tim-loop-contract.md' >> "$WORKTREE_GITDIR/info/exclude"
echo '.tim-loop-resume.json' >> "$WORKTREE_GITDIR/info/exclude"
echo 'tim-loop-results.tsv' >> "$WORKTREE_GITDIR/info/exclude"
```

Record the `base_branch` (the branch HEAD was on before worktree creation).

Builder worktrees are created LATER in Step 5b, after the architect defines partitions.

### Step 3: Create Team

```
TeamCreate:
  team_name: "tim-loop-{feature-slug}"
  description: "Tim Loop: automated build-verify-review for {feature-name}"
```

### Step 4: Read Prompt Templates

Read these files from the skill directory (`~/.claude/skills/tim-loop/`):
- `tim-architect.md` — architect agent prompt template
- `tim-builder.md` — builder agent prompt template
- `tim-verifier.md` — verifier agent prompt template
- `tim-reviewer.md` — reviewer agent prompt template
- `tim-auditor.md` — auditor agent prompt template
- `tim-verify.md` — verification strategy reference
- `tim-evaluation-calibration.md` — scoring criteria, thresholds, and calibration examples

### Step 5: Spawn Initial Agents

Spawn the architect, verifier, and reviewer using the Agent tool with `team_name` parameter.
Builders are spawned LATER, after the architect produces partitions.

For each agent, fill in the placeholders from their prompt template with:
- `{TEAM_NAME}` — the team name from Step 3
- `{FEATURE_NAME}` — from the spec heading
- `{SPEC_CONTENT}` — full spec text (embedded, not a file path)
- `{VERIFY_STRATEGY_CONTENT}` — full content of tim-verify.md
- `{SPEC_VERIFICATION_OVERRIDES_OR_NONE}` — from spec's `## Verification` section, or "None"
- `{OPEN_QUESTIONS}` — from spec's `## Open Questions` section, or "None"
- `{TEST_STRATEGY}` — from spec's `## Test Strategy` section, or "None"
- `{BUILDER_COUNT}` — from Loop Config, or "auto"
- `{MAX_BUILDERS}` — from Loop Config, or "5"
- `{METRIC_MODE}` — "metric" or "pass_fail"
- `{METRIC_COMMAND}` — from spec's `## Verify Command`, or "None"
- `{METRIC_DIRECTION}` — from spec's `## Metric` Direction field, or "None"
- `{GUARD_COMMANDS}` — from spec's `## Guards` section, or "None"
- `{INTEGRATION_WORKTREE}` — path to the integration worktree
- `{VERIFIER_DISCOVERY}` — "None" on initial spawn; filled from baseline task metadata on refresh
- `{BUILDER_WORKTREES}` — "None" on initial spawn; filled after builder worktrees are created
- `{USER_JOURNEYS}` — from spec's `## User Journeys` section, or "None"
- `{CONNECTIONS_MAP}` — from architect contract's `## Connections` section (filled after architect phase), or "None"
- `{CONTRACT_CONTENT}` — full text of `.tim-loop-contract.md` (filled after architect phase), for auditor
- `{SPEC_REQUIREMENTS}` — the `## Requirements` section content from the spec (for embedding in auditor task)
- `{SPEC_ACCEPTANCE_CRITERIA}` — the `## Acceptance Criteria` section content from the spec (for embedding in auditor task)
- `{COMPILER_TRAPS}` — from spec's `## Compiler Traps` section, or "None"
- `{PARTITION_COMPLEXITY}` — "NORMAL" or "HIGH" from architect contract's partition complexity field
- `{DONE_CONTRACT}` — builder's negotiated done-contract from Step 0.5, or "None"
- `{PARTITION_ASSIGNMENTS}` — partition-to-requirement mapping for auditor subagent dispatch
- `{TOTAL_REQUIREMENT_COUNT}` — count of all requirements + acceptance criteria
- Other placeholders filled as the loop progresses

The architect will study the codebase and produce the implementation contract.
The verifier will identify available test runners and frameworks.
The reviewer will study the codebase as part of its initial turn.

Wait for all 3 agents to report ready before proceeding to the Architect Phase.

### Step 5a: Run Spike Tasks (if present in spec)

If the spec has a `## Spike Tasks` section, run each spike BEFORE the architect phase.
Spike tasks verify assumptions about hardware, undocumented APIs, or platform behavior
that would otherwise propagate as wrong assumptions into the contract and all builders.

For each spike task:
1. Run the command in the integration worktree
2. Capture the output
3. Compare against the expected result
4. If a spike FAILS: warn the user and ask how to proceed:
   - Update the spec requirement to mark the approach as "TBD"
   - Try an alternative approach (user provides)
   - Proceed anyway (user accepts the risk)
5. If a spike PASSES: record the verified information for the architect

Pass spike results to the architect as `{SPIKE_RESULTS}` so the contract
is based on verified behavior, not assumptions.

### Step 5b: Architect Phase

1. Create task for the architect (working in the integration worktree):
   ```
   TaskCreate:
     subject: "Produce implementation contract for {FEATURE_NAME}"
     description: |
       Study the codebase and the spec. Produce an implementation contract:
       - Write shared types/interfaces to disk (compilable, importable)
       - Define naming conventions, error handling patterns, test patterns
       - Create N partitions with non-overlapping file ownership
       - Map every spec requirement to exactly one partition
       - Builder count: {BUILDER_COUNT} (auto = you decide; integer = exact count)
       - Max builders: {MAX_BUILDERS}
       Write the contract to .tim-loop-contract.md in the worktree root.
       Submit via ExitPlanMode for orchestrator approval.
     owner: architect
   ```

2. Wait for architect to submit plan via ExitPlanMode.

3. Review the contract:
   - Does every P0 requirement appear in a partition?
   - Does every P1/P2 requirement appear in a partition?
   - Are partition file sets non-overlapping?
   - Were shared contracts actually written to disk?
   - Is the partition count within max_builders?
   - Does it include a `## Connections` section? (required even if empty)
   - **Contradiction check:** Do any partitions require capabilities that conflict
     with settings owned by another partition? (e.g., one partition needs sandbox
     disabled for IOKit but another partition's notes say sandbox is enabled)
   - **Isolation check:** Does every partition say "Can compile/test independently: YES"?
     If any partition says "PARTIALLY" or "NO", REJECT the contract. The architect
     must either merge dependent partitions, create proper interface stubs in shared
     contracts, or restructure so each partition compiles in isolation.
   - **Spike alignment check:** If spike tasks ran (Step 5a), verify the contract's
     implementation notes align with spike results. Reject if the contract prescribes
     an approach that a spike disproved.
   If not: reject with specific feedback (SendMessage type: plan_approval_response, approve: false).
   If acceptable: approve (approve: true).

4. Read the approved contract. Extract:
   - `partitions` — array of { name, files, requirements, dependencies, iteration_budget, complexity }
   - `contract_content` — full text of .tim-loop-contract.md
   - `partition_count` — number of partitions
   - `partition_assignments` — formatted string mapping each partition to its requirements (for auditor subagent dispatch)
   - `total_requirement_count` — count of all requirements + acceptance criteria (for auditor adaptive threshold)
   - `connections_map` — the `## Connections` section content (for verifier Phase 3c)

   For each partition, parse `iteration_budget` if present:
   - `partition.iteration_budget = min(parsed_value, MAX_BUILDER_ITERATIONS)`
   - If not specified: `partition.iteration_budget = MAX_BUILDER_ITERATIONS`

5. **Create per-builder worktrees:** For each partition, create a worktree branching from the integration branch:

   ```bash
   # For each partition:
   git worktree add <worktree-base>/builder-{index} -b tim-loop/{feature-slug}/builder-{index} tim-loop/{feature-slug}/integration
   ```

   This ensures every builder starts with the architect's shared contracts already present.

   When `partition_count == 1`: create a single builder worktree. The builder has no scope restrictions.

6. **Spawn builders:** For each partition, spawn a builder agent:
   ```
   Agent tool (general-purpose):
     name: "builder-{partition_index}" (or just "builder" if partition_count == 1)
     team_name: "{TEAM_NAME}"
     description: "Build: {partition_name}"
     mode: "bypassPermissions"
     prompt: (filled from tim-builder.md template with partition scope + worktree path)
   ```

   Each builder's prompt includes `{BUILDER_WORKTREE}` — the path to their isolated worktree.

7. Send `shutdown_request` to architect. Wait for confirmation.

8. Wait for all builders to report ready before starting the loop.

### Step 6: Baseline Verification (unless `skip_baseline` is true)

Create a task for the verifier to run all checks on the clean integration worktree
BEFORE the builder touches anything:

```
TaskCreate:
  subject: "Run baseline verification"
  description: "Run all guard checks and Tier 1 checks on the clean integration worktree
    before any changes. Record which checks already fail.
    Also report the test infrastructure you discovered.
    If spec has Guards section, run each guard command and record results.
    If spec has Verify Command, run it to capture baseline metric value.
    Report baseline, discovery, and metric baseline as task metadata:
      metadata: {
        baseline_failures: ['tier1/test/auth.test.ts:42', ...],
        baseline_metric: 72.3,  // or null if no metric
        metric_sanity: 'ok',  // or 'warning: metric returned 2 but test runner reports 100 tests'
        discovery: {
          test_runner: 'vitest',
          test_command: 'npm test',
          lint_command: 'npm run lint',
          typecheck_command: 'npx tsc --noEmit',
          build_command: 'npm run build',
          frameworks: ['vitest', 'eslint', 'typescript'],
          browser_tool: 'gstack'  // or 'playwright-cli' | 'claude-in-chrome' | null
        }
      }"
  owner: verifier
```

Wait for verifier to complete this task.

Record the baseline, baseline_metric, AND the verifier discovery.

## Surface metric warnings to user
if baseline_task_metadata.metric_sanity starts with "warning":
  Tell user: "Metric warning: {baseline_task_metadata.metric_sanity}. The verify command may not produce meaningful numbers. Continue with metric mode, or switch to pass/fail?"
  ## If user says switch: set metric_mode = "pass_fail"

Initialize the TSV progress log:

```
## Write header + baseline row to tim-loop-results.tsv in integration worktree
cycle\tphase\tbuilder\titeration\tmetric\tguard\tstatus\tduration_s\tstart_ts\tend_ts\tdescription
0\tBASELINE\t-\t0\t{baseline_metric}\tpass\tbaseline\t{duration}\t{start_ts}\t{end_ts}\tinitial state
```

## THE LOOP

```
outer_cycle = 1
pr_number = null
baseline, baseline_metric, verifier_discovery = (from Step 6, or empty/null if skipped)

while outer_cycle <= MAX_OUTER_CYCLES:

  ## 0.5. CONTRACT NEGOTIATION (mandatory on cycle 1)
  if outer_cycle == 1:
    Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Negotiating done-contracts with builders..."
    ## ENFORCEMENT: Contract negotiation is MANDATORY on cycle 1.
    ## Do NOT skip this step. The Orion Dashboard retro showed that skipping
    ## contract negotiation prevented catching semantic errors early.
    ## If you are tempted to jump straight to BUILD, STOP. Run this step.

    ## For each active partition, ask the builder to propose what "done" looks like.
    ## The verifier reviews each proposal. Max 2 rounds per partition.

    for each active partition (parallel):
      TaskCreate:
        subject: "Propose done contract for {partition.name}"
        description: |
          Write a brief done-contract for your partition. Include:
          1. What you'll build (specific files, functions, endpoints)
          2. What should be tested (specific behaviors, edge cases)
          3. What constitutes pass (concrete, measurable criteria)
          Submit via TaskUpdate with metadata: { contract: "..." }
        owner: {partition.builder_name}

    Wait for all proposals. For each:
      TaskCreate:
        subject: "Review builder-{N} contract for {partition.name}"
        description: |
          Review this builder's proposed done-criteria. Push back if:
          - Testable criteria are vague ("it should work")
          - Edge cases not mentioned
          - Success conditions unmeasurable
          Report: metadata: { approved: true/false, feedback: "..." }

          Builder's proposal:
          {builder_contract_from_metadata}
        owner: verifier

    Wait for all reviews.
    for each rejected contract (round < 2):
      Route feedback to builder, request revised proposal.
      Wait for revision, re-route to verifier.
    for any still rejected after 2 rounds:
      Log warning: "Contract not fully approved, proceeding with builder's latest proposal."

    ## Persist done-contracts for downstream use
    done_contracts = {}
    for each partition:
      done_contracts[partition.builder_name] = builder_contract_from_metadata
    ## done_contracts are passed to build tasks, verification, resume, and refresh

    ## Log contract negotiation to TSV
    append_tsv_row(outer_cycle, "CONTRACT", "-", 0, null, "pass", "complete", duration_s, start_ts, end_ts, "contract negotiation")

  ## 1. BUILD (with keep/discard iteration per builder)
  Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Starting build ({partition_count} builder(s))..."

  ## Create parallel build tasks for each non-NEEDS_HUMAN partition:
  TaskCreate (one per active partition):
    subject: "Build partition: {partition.name} (cycle {outer_cycle})"
    description: |
      You are building partition "{partition.name}" in your isolated worktree.
      Worktree path: {partition.builder_worktree}
      Your file scope: {partition.files}
      Your requirements: {partition.requirements}
      Your done-contract (what you committed to deliver):
      {done_contracts[partition.builder_name] or "No done-contract (cycle 2+ or negotiation skipped)"}
      Implementation contract: {contract_content}

      ## Iteration Discipline (autoresearch-style)

      For each logical change:
      1. Make ONE atomic change (if you need "and" to describe it, split it)
      2. Commit with conventional message
      3. Run guard checks: {GUARD_COMMANDS or "typecheck + lint + existing tests"}
      4. If guard FAILS: `git revert HEAD` immediately — you broke something
      5. If guard PASSES and metric_mode == "metric": run verify command, record metric
         - Metric improved? KEEP (commit stays, advance)
         - Metric same/worse? DISCARD (`git revert HEAD`), try different approach
      6. If guard PASSES and metric_mode == "pass_fail": KEEP (commit stays)

      Max iterations: {partition.iteration_budget or MAX_BUILDER_ITERATIONS}
      Report each iteration outcome in task metadata as it happens:
        metadata.iterations: [{metric: N, guard: "pass"|"fail", status: "keep"|"discard"|"revert", description: "..."}]

      When all requirements are implemented (or max iterations reached),
      mark this task complete with final metadata:
        metadata: { final_metric: N, iterations_used: M, keeps: K, discards: D }

      {If cycle 2+: "Incorporate findings for your partition: {partition_findings}"}
    owner: {partition.builder_name}

  Wait for ALL build tasks to complete.

  ## Post-build: read iteration results from each builder's task metadata.
  ## Log all iterations to TSV. Track consecutive discard streaks per builder.

  ## Stuck detection: if any builder hit 3+ consecutive discards:
  if builder hit 3+ consecutive discards AND rethink not yet attempted:
    Tell user: "Attempting radical rethink for {builder}..."
    TaskCreate:
      subject: "Radical rethink: {partition.name} (cycle {outer_cycle})"
      description: |
        You hit 3 consecutive discards. Re-read the spec and your git log,
        then try a fundamentally different approach. Use remaining iteration
        budget for the rethink. Report outcome in task metadata.
      owner: {partition.builder_name}

    Wait for rethink task.
    if rethink succeeded:
      Tell user: "Radical rethink succeeded."
    else:
      partition.status = "needs_human"
      if not all_partitions_independent(partitions):
        ABORT("Builder stagnant on dependent partition after rethink.")

  elif builder hit 3+ consecutive discards AND rethink already attempted:
    partition.status = "needs_human"
    if not all_partitions_independent(partitions):
      ABORT("Builder stagnant on dependent partition.")

  Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Build complete. Starting integration..."

  ## 2. INTEGRATE — Reviewer merges builder branches into integration
  Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Merging builder branches into integration..."

  TaskCreate:
    subject: "Integrate builder branches (cycle {outer_cycle})"
    description: |
      Merge each builder's branch into the integration branch, one at a time.
      Integration worktree: {INTEGRATION_WORKTREE}

      For each builder (in order of partition index):
        1. cd {INTEGRATION_WORKTREE}
        2. git merge tim-loop/{feature-slug}/builder-{index} --no-edit
        3. If merge conflict:
           - Report which files conflict
           - Report which builder's changes caused the conflict
           - Set metadata: { merge_conflict: true, conflicting_builder: "builder-{N}", files: [...] }
           - Mark task as completed (orchestrator handles routing)
        4. After each successful merge, run guard checks:
           - {GUARD_COMMANDS or "typecheck + lint + existing tests + build"}
           - If guard fails after a merge, record which builder's merge broke it

      After ALL merges succeed and guards pass:
        - If metric_mode == "metric": run verify command, record integrated metric
        - Report in metadata: {
            merge_conflicts: false,
            guard_status: "pass"|"fail",
            failed_after_builder: null|"builder-N",
            integrated_metric: N
          }
    owner: reviewer

  Wait for reviewer to complete integration task. Read integration metadata.

  if merge_conflicts:
    Route conflict to the conflicting builder with a resolve task (rebase on integration).
    Wait for resolution. Retry integration from the conflicting builder onward.

  if guard_status == "fail":
    Route guard failure to the builder whose merge broke it (failed_after_builder).
    Send fix task to that builder, re-attempt integration after fix.

  ## 3. VERIFY INTEGRATION (three-phase)
  Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Verifying integrated build..."

  TaskCreate:
    subject: "Verify integrated build (cycle {outer_cycle})"
    description: |
      Verify the fully integrated build in the integration worktree.
      Integration worktree: {INTEGRATION_WORKTREE}
      Baseline failures (ignore these): {baseline}
      Baseline metric: {baseline_metric}

      Done-contracts (verify builders delivered what they committed to):
      {done_contracts or "None (negotiation did not run)"}
      If done-contracts are present, include done_contract_adherence in metadata:
      For each builder's done-contract, check whether each committed item was delivered.

      Run THREE-PHASE verification:

      PHASE 1 — GUARD CHECK: Run all guard commands. ALL must pass.
        {GUARD_COMMANDS or "typecheck + lint + existing tests + build"}
        If any guard fails → FAIL immediately, skip Phase 2+3.

      PHASE 2 — FEATURE VERIFICATION: Run Tier 1-3 checks for new functionality.
        If metric_mode == "metric": Run verify command, extract metric value.
        Phase 2b: Live data verification (if spec has external API routes or Data Mapping).
        PLAN ADHERENCE: Check implementation against spec requirements.
        DEFENSIVE REVIEW: Input validation, security, atomicity, data consistency.
        If Phase 2 fails → FAIL, skip Phase 3.

      PHASE 3 — INTEGRATION COMPLETENESS (only if Phase 1+2 pass):
        3a. Stub/placeholder scan: grep diff for TODO, FIXME, empty functions, hardcoded mocks
        3b. Dead export detection: check new exports are actually imported somewhere
        3c. Connection verification using architect contract connections map:
            {CONNECTIONS_MAP}
        3d. User journey smoke tests (execute in browser):
            {USER_JOURNEYS}
            Take screenshots at each checkpoint as evidence.
        3e. Protocol/interface consistency: verify shared protocol signatures match
            their implementations AND call sites (catches multi-partition signature drift)
        3f. Deployment readiness: verify build output is compatible with deployment
            target (if deployment config present — e.g., Railway, Docker, Fly)

      Report in task metadata: {
        verdict: "PASS"|"FAIL",
        guard_status: "pass"|"fail",
        feature_metric: N,
        metric_delta: +/-N (compared to baseline),
        integration_completeness: { stubs_found, dead_exports_found, missing_connections, journeys_passed, journeys_total, journey_screenshots },
        failure_keys: [...],
        prognosis: "FIXABLE"|"NEEDS_HUMAN"|"UNCLEAR"
      }
      On FAIL: send detailed findings to relevant builders via SendMessage.
    owner: verifier

  Wait for verifier to complete the verify task.
  Read task metadata for: verdict, failure_keys, prognosis, feature_metric, plan_adherence.

  ## Log integration verification to TSV (include phase and duration)
  append_tsv_row(outer_cycle, "VERIFY", "integration", 0, feature_metric, guard_status, verdict, duration_s, start_ts, end_ts, "integrated verify")

  if verdict == "PASS":
    Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Integration verify PASS."
    ## Proceed to publish

  elif verdict == "FAIL":
    if prognosis == "NEEDS_HUMAN":
      ABORT("Verifier reports issue needing human intervention.")

    Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Integration verify FAIL ({prognosis}). Routing fixes..."

    ## Route failure_keys to owning builders by file path.
    ## Special case: cross-partition dead exports.
    ## When a dead export finding (integration/dead-export/*) involves a function
    ## in partition A's files that should be imported by partition B's files:
    ##   - Check if the consuming file is in a different partition than the export
    ##   - If cross-partition: route directly to the REVIEWER (who works in the
    ##     integration worktree where all files are merged) instead of to a builder
    ##     (who can't see the other partition's files)
    ##   - Log: "Cross-partition dead export — routing to reviewer for integration-level fix"
    ## Unroutable items → builder-1.
    ## Create fix tasks for each builder with failures. Builders fix in their own worktrees.
    Wait for all fix tasks to complete.
    ## Re-attempt integration (max 2 re-integration attempts per cycle).
    ## If still failing after 2 re-integrations, proceed to review with known issues.

  ## 4. PUBLISH
  Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Publishing..."

  TaskCreate:
    subject: "Publish PR (cycle {outer_cycle})"
    description: |
      The integration branch is verified. Push and create/update PR.
      Integration worktree: {INTEGRATION_WORKTREE}

      ## Artifact Cleanup (do this FIRST, before pushing)

      Remove tim-loop artifacts from git tracking if they leaked in:
      ```bash
      cd {INTEGRATION_WORKTREE}
      git rm --cached --ignore-unmatch .tim-loop-contract.md .tim-loop-resume.json tim-loop-results.tsv 2>/dev/null
      # If anything was unstaged, commit the removal
      git diff --cached --quiet || git commit -m "chore: remove tim-loop artifacts from tracking"
      ```

      ## Push and PR

      {If pr_number == null: "Push the integration branch and create a new PR against {base_branch}.
       Include spec requirements as a checklist in the PR description.
       Mark P0/P1/P2 items with their priority. Check off completed items.
       Include requirements from ALL partitions, grouped by partition name.
       Include a metrics summary if metric_mode == 'metric':
         Baseline: {baseline_metric} → Final: {feature_metric} ({metric_delta})"}
      {If pr_number != null: "Push updates to PR #{pr_number}.
       Update the PR description checklist with newly completed items."}
      Report the PR number and URL in task metadata:
        metadata: { pr_number: 47, pr_url: "https://..." }
    owner: reviewer

  Wait for reviewer to complete publish task.
  Read pr_number from task metadata.

  ## 5. REVIEW (parallel: reviewer + auditor)
  Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Reviewing PR #{pr_number}..."

  ## Spawn auditor just-in-time (fresh context window for deep spec review)
  Agent tool (general-purpose):
    name: "auditor"
    team_name: "{TEAM_NAME}"
    description: "Audit: {FEATURE_NAME}"
    mode: "bypassPermissions"
    prompt: (filled from tim-auditor.md template with all placeholders)

  ## Create TWO tasks in parallel — reviewer handles CI + code quality,
  ## auditor handles deep spec completeness. Both must pass.

  TaskCreate (reviewer task):
    subject: "Review PR #{pr_number} (cycle {outer_cycle})"
    description: |
      Review PR #{pr_number} for CI status and code quality.
      Cycle {outer_cycle} of {MAX_OUTER_CYCLES}.
      Integration worktree: {INTEGRATION_WORKTREE}

      ## CI Checks (mandatory — do this FIRST)

      1. Wait for CI: `gh pr checks {PR_NUMBER} --watch --fail-fast`
         - Timeout after 10 minutes — if still pending, report as BLOCKING with category `ci-timeout`
      2. If any checks fail: `gh pr checks {PR_NUMBER} --json name,state,link --jq '.[] | select(.state != "SUCCESS" and .state != "SKIPPED")'`
      3. For each failing check, inspect logs: `gh run view {RUN_ID} --log-failed`
         - Map failures to owning builders by file path when possible
      4. Each failing CI check = a BLOCKING finding (category: "ci-failure")
      5. CI must be fully green for a PASS verdict

      ## Artifact Check (pure verification — do NOT modify the worktree)

      Verify no tim-loop artifacts leaked into the diff:
      ```bash
      gh pr diff {PR_NUMBER} | grep -q '\.tim-loop-contract\.md\|\.tim-loop-resume\.json\|tim-loop-results\.tsv'
      ```
      If any match: BLOCKING finding (category: "artifact-in-diff", description: "{filename} is in the diff — the publish step should have cleaned this up").
      Do NOT attempt remedial cleanup — the auditor may be reading the worktree in parallel.

      ## Code Review

      Review code quality using `gh pr diff`. Use structured findings.

      ## NOTE: Spec completeness is handled by the dedicated auditor agent.
      ## Your verdict covers CI + code quality ONLY.

      Report verdict, prognosis, CI status, and findings in task metadata:
        metadata: {
          verdict: "PASS"|"FAIL",
          prognosis: "...",
          blocking_count: N,
          ci_status: "pass"|"fail"|"timeout",
          ci_checks: { total: N, passed: N, failed: N, pending: N },
          findings: [...]
        }
    owner: reviewer

  TaskCreate (auditor task):
    subject: "Deep spec audit (cycle {outer_cycle})"
    description: |
      Perform deep spec completeness audit in the integration worktree.
      Integration worktree: {INTEGRATION_WORKTREE}

      ## Spec Requirements (audit EVERY one)

      {SPEC_REQUIREMENTS}

      ## Acceptance Criteria (audit EVERY one — gate same as P0)

      {SPEC_ACCEPTANCE_CRITERIA}

      ## Architect Contract

      {CONTRACT_CONTENT}

      ## Connections Map

      {CONNECTIONS_MAP}

      ## User Journeys

      {USER_JOURNEYS}

      ## Partition Assignments (for subagent dispatch if requirements > 15)

      {PARTITION_ASSIGNMENTS}
      (Format: partition name -> builder name -> requirement list + applicable acceptance criteria.
      The auditor uses this to group requirements by partition when dispatching subagents.
      Acceptance criteria that span multiple partitions are included in each relevant partition.)

      Total requirements: {TOTAL_REQUIREMENT_COUNT}
      (If > 15: use Adaptive Audit Mode with per-partition subagents.
       If <= 15: audit directly without subagents.)

      For each requirement and acceptance criterion:
      1. Grep to find implementation → Read the source file → classify REAL/STUB/MISSING
      2. Grep to find tests → Read the test file → classify THOROUGH/SHALLOW/MISSING
      3. Trace integration wiring from entry point → classify WIRED/ORPHAN
         (only for features with User Journeys — skip for background jobs, webhooks, etc.)
      4. Score confidence: HIGH/MEDIUM/LOW
      5. Verify architect's shared contracts are imported by consuming partitions
      6. Trace entry-point reachability for new user-facing features

      Produce compliance_report (markdown table) for the PR description.

      Report deep_audit, connection_audit, contract_usage, reachability,
      compliance_report, findings, and summary in task metadata.
    owner: auditor

  Wait for BOTH tasks to complete.
  Read reviewer metadata: reviewer_verdict, reviewer_findings, ci_status, ci_checks
  Read auditor metadata: auditor_verdict, deep_audit, compliance_report, auditor_findings

  ## Cross-Agent Verification Triangulation
  ## Compare auditor's deep_audit with verifier's plan_adherence to catch disagreements.
  if verifier's plan_adherence is available from the Phase 3 verify task:
    for each requirement in deep_audit:
      verifier_entry = find matching requirement in plan_adherence
      if verifier_entry and verifier_entry.status == "IMPLEMENTED" and requirement.impl_status == "STUB":
        Tell user: "TRIANGULATION ALERT: Verifier's grep found '{requirement.requirement}' but auditor assessed it as STUB after reading the source."
        auditor_findings.append({
          severity: "BLOCKING",
          category: "triangulation-disagreement",
          description: "Verifier grep found evidence but auditor read the source and classified as STUB: {requirement.impl_assessment}",
          requirement: requirement.requirement,
          builder: (route by file path of requirement.impl_file)
        })

  ## Check done-contract adherence from verify metadata
  done_contract_failures = []
  if verify_task_metadata.done_contract_adherence:
    for item in verify_task_metadata.done_contract_adherence:
      if item.status == "NOT_DELIVERED":
        done_contract_failures.append({
          severity: "BLOCKING",
          category: "done-contract-breach",
          description: "Builder {item.builder} committed '{item.committed}' but did not deliver. Evidence: {item.evidence}",
          builder: item.builder
        })

  ## Combine verdicts: both reviewer AND auditor must pass, AND all scores must be ≥ 6
  combined_findings = reviewer_findings + auditor_findings + done_contract_failures

  ## Quality Score Gate — check verifier and auditor scores against thresholds
  ## Read verifier quality_scores from the VERIFY phase metadata
  verifier_scores = verify_task_metadata.quality_scores  (from Phase 3 task)
  auditor_scores = auditor_metadata.quality_scores
  verifier_rationale = verify_task_metadata.score_rationale  (from Phase 3 task)
  auditor_rationale = auditor_metadata.score_rationale

  all_scores = {**(verifier_scores or {}), **(auditor_scores or {})}
  all_rationale = {**(verifier_rationale or {}), **(auditor_rationale or {})}
  score_failures = [dim for dim, score in all_scores.items() if score < 6]

  if score_failures:
    Tell user: "Quality score(s) below threshold: {score_failures}"
    for dim in score_failures:
      combined_findings.append({
        severity: "BLOCKING",
        category: "quality-score-below-threshold",
        description: "{dim}: {all_scores[dim]}/10 — below minimum threshold of 6. Rationale: {all_rationale[dim]}",
        builder: (route by dimension: implementation_depth/test_thoroughness → auditor's impl_file owners,
                  functional_completeness/integration_coherence → verifier's failure_key owners,
                  code_health/spec_fidelity → builder-1 default)
      })

  ## Validate auditor's deep_audit before accepting any verdict
  if deep_audit is missing or empty:
    Tell user: "Auditor did not produce deep_audit. Treating as FAIL."
    final_verdict = "FAIL"
    prognosis = "FIXABLE"
  else:
    ## Check P0 requirements AND acceptance criteria (priority "AC") for gaps
    ## P0/AC must have impl_status=REAL and test_status != MISSING and confidence != LOW
    critical_gaps = [r for r in deep_audit
      if (r.priority == "P0" or r.priority == "AC")
      and (r.impl_status != "REAL" or r.test_status == "MISSING" or r.confidence == "LOW")]

    ## Also check: reachability failures for user-facing features are BLOCKING
    reachability_failures = [r for r in (auditor_findings or []) if r.category == "unreachable-feature"]

    ## Contract usage gaps are BLOCKING if the consuming partition has P0 requirements
    contract_failures = [r for r in (auditor_findings or []) if r.category == "contract-unused"]

    all_blocking = critical_gaps + reachability_failures + contract_failures

    if all_blocking:
      if reviewer_verdict == "PASS":
        Tell user: "Reviewer passed CI+quality but auditor found {len(all_blocking)} issue(s)."
      final_verdict = "FAIL"
      prognosis = "FIXABLE"
      for gap in critical_gaps:
        combined_findings.append({
          severity: "BLOCKING",
          category: "auditor-p0-gap",
          description: "P0/AC '{gap.requirement}': impl={gap.impl_status}, test={gap.test_status}, confidence={gap.confidence}",
          builder: (route by file path: stub-impl/shallow-test → file owner,
                    contract-unused → partition's builder from architect contract,
                    unreachable-feature → UI partition builder,
                    triangulation-disagreement → file owner of impl_file,
                    default → builder-1)
        })
    elif reviewer_verdict == "FAIL":
      final_verdict = "FAIL"
      prognosis = reviewer's prognosis
    elif score_failures:
      final_verdict = "FAIL"
      prognosis = "FIXABLE"
      Tell user: "All tests pass and audit clean, but quality scores below threshold: {score_failures}"
    else:
      final_verdict = "PASS"

  ## Write compliance report to PR using idempotent section markers
  if compliance_report:
    ## Use section markers to support idempotent updates across cycles
    ## Read current PR body, replace between markers (or append if markers don't exist)
    current_body = $(gh pr view {pr_number} --json body -q .body)
    if current_body contains "<!-- SPEC-COMPLIANCE-START -->":
      ## Replace existing compliance section
      new_body = current_body with text between <!-- SPEC-COMPLIANCE-START --> and <!-- SPEC-COMPLIANCE-END --> replaced with compliance_report
    else:
      ## Append with markers
      new_body = current_body + "\n\n<!-- SPEC-COMPLIANCE-START -->\n" + compliance_report + "\n<!-- SPEC-COMPLIANCE-END -->"
    ## Wrap in error handling — failure to post report should not affect verdict
    try: gh pr edit {pr_number} --body "$new_body"
    catch: Tell user: "Warning: Failed to update PR with compliance report. Verdict unaffected."

  if final_verdict == "PASS":
    Tell user: "Review PASS (CI: {ci_checks.passed}/{ci_checks.total} green, audit: {deep_audit.summary.high_confidence} HIGH / {deep_audit.summary.medium_confidence} MEDIUM confidence, scores: {all_scores}). PR #{pr_number} ready for human review."
    ## Log final state to TSV
    append_tsv_row(outer_cycle, "REVIEW", "review", 0, feature_metric, "pass", "PASS", duration_s, start_ts, end_ts, "review approved")
    Tell user final metrics summary if metric_mode == "metric":
      "Metric: {baseline_metric} → {feature_metric} ({metric_delta})"
    Invoke superpowers:finishing-a-development-branch
    CLEANUP_BUILDER_WORKTREES()
    SHUTDOWN_TEAM()
    DONE.

  elif final_verdict == "FAIL":
    if prognosis == "NEEDS_HUMAN":
      ABORT("Review reports issue needing human intervention.")

    ## Report CI status to user when CI contributed to the failure
    ci_failures = [f for f in reviewer_findings if f.category == "ci-failure" or f.category == "ci-timeout"]
    if ci_failures:
      Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: CI failing ({ci_checks.failed} check(s)). Routing to builders..."

    ## Route combined findings to relevant builders.
    ## Routing rules for new finding types:
    ##   stub-impl / shallow-test → route by impl_file path to owning builder
    ##   contract-unused → route to the builder whose partition should consume the contract
    ##   unreachable-feature → route to the builder who owns the page/route registration
    ##   triangulation-disagreement → route to the builder who owns the file flagged as STUB
    ##   ci-failure with builder == null → route to builder-1 (default)

    if outer_cycle < MAX_OUTER_CYCLES:
      Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Review FAIL. Refreshing agents for cycle {outer_cycle + 1}..."
      REFRESH_AGENTS(cycle_number = outer_cycle + 1, with combined findings routed to builders)

    outer_cycle += 1

// All cycles exhausted
Tell user: "{MAX_OUTER_CYCLES} cycles exhausted. PR #{pr_number} exists but has unresolved findings."
ABORT("All cycles exhausted.")
```

## ABORT Procedure

When aborting for any reason:

1. **Tell the user:**
   - Which cycle/attempt failed
   - What the prognosis was
   - What the unresolved issues are (from last verifier/reviewer task metadata)
   - Metrics summary if metric_mode == "metric"

2. **Preserve work and state:**
   - The worktree branches are NOT deleted
   - Write a resume state file to the integration worktree root:
     ```json
     // .tim-loop-resume.json
     {
       "team_name": "tim-loop-{feature-slug}",
       "spec_path": "/path/to/spec.md",
       "contract_path": ".tim-loop-contract.md",
       "base_branch": "main",
       "integration_worktree": "/path/to/integration",
       "builder_worktrees": {
         "builder-1": "/path/to/builder-1",
         "builder-2": "/path/to/builder-2"
       },
       "pr_number": 47,
       "outer_cycle": 2,
       "metric_mode": "metric",
       "baseline_metric": 72.3,
       "latest_metric": 85.1,
       "done_contracts": {
         "builder-1": "## Builder-1 Done Contract\n### Will Build\n...",
         "builder-2": "## Builder-2 Done Contract\n..."
       },
       "verifier_discovery": {
         "test_runner": "vitest",
         "test_command": "npm test",
         "lint_command": "npm run lint",
         "typecheck_command": "npx tsc --noEmit",
         "build_command": "npm run build",
         "frameworks": ["vitest", "eslint", "typescript"],
         "browser_tool": "gstack"
       },
       "partitions": [
         {
           "name": "auth-module",
           "builder_name": "builder-1",
           "builder_worktree": "/path/to/builder-1",
           "files": ["src/auth/*", "tests/auth/*"],
           "requirements": ["[P0] JWT validation", "[P0] Session management"],
           "status": "completed",
           "last_metric": 85.1,
           "rethink_attempted": false
         },
         {
           "name": "payment-module",
           "builder_name": "builder-2",
           "builder_worktree": "/path/to/builder-2",
           "files": ["src/payments/*", "tests/payments/*"],
           "requirements": ["[P0] Payment processing", "[P1] Refund handling"],
           "status": "fixing",
           "last_metric": 45.0,
           "rethink_attempted": true
         }
       ],
       "abort_reason": "Builder builder-2 stagnant after rethink.",
       "last_deep_audit": [],
       "last_auditor_findings": []
     }
     ```
   - Tell user the branch names and resume file location
   - Tell user: "Run `/tim-loop --resume <integration-worktree-path>` to continue."

3. **Shut down team:**
   - Send `shutdown_request` to all agents
   - Wait for confirmations
   - TeamDelete
   - Do NOT delete worktrees (user may want to inspect)

## RESUME Procedure (when invoked with `--resume` or a `.tim-loop-resume.json` path)

1. Read the resume state file
2. Read the spec from `spec_path`
3. Read the contract from `contract_path` (already on disk in the integration worktree)
4. Extract `verifier_discovery` from the resume state (if present)
5. Verify all worktrees still exist (integration + builder worktrees)
6. Create a new team (old agents are gone — no session resumption for teammates)
7. Spawn fresh verifier with `verifier_discovery` from resume state (so it skips re-discovery)
8. Spawn fresh reviewer agent
9. Spawn builders ONLY for partitions with status not in ("completed", "needs_human"):
   - For each incomplete partition, spawn a builder with that partition's scope and worktree path
   - Completed partitions do not need a builder
   - Do NOT re-spawn the architect — the contract is already on disk
10. Read the existing task list to see what was completed before the abort
11. Skip to the phase where the abort occurred
12. Continue the loop from there

## CLEANUP_BUILDER_WORKTREES Procedure

Called on successful completion to clean up builder worktrees (integration worktree
is kept since it has the PR branch):

```bash
for each builder worktree:
  git worktree remove <builder-worktree-path> --force
  git branch -d tim-loop/{feature-slug}/builder-{index}
```

## SHUTDOWN_TEAM Procedure

1. Send `shutdown_request` to ALL builders (builder-1, builder-2, ..., builder-N, or just "builder" in single mode)
2. Send `shutdown_request` to verifier and reviewer
3. Wait for all to confirm
4. Call TeamDelete to clean up team resources

## REFRESH_AGENTS Procedure

Called between outer cycles to give all agents fresh context windows.
The team and task list persist — only agents are swapped.
Builder worktrees persist — fresh builders pick up where the old ones left off.

```
REFRESH_AGENTS(cycle_number, reviewer_findings_by_builder, pr_number, baseline, partitions, contract_content, verifier_discovery, done_contracts):

  ## 1. Shutdown all current agents in parallel
  Send shutdown_request to ALL builders, verifier, and reviewer simultaneously.
  Wait for all confirmations.

  ## 2. Re-read prompt templates from disk
  Re-read tim-builder.md, tim-verifier.md, tim-reviewer.md, tim-verify.md.
  (Templates may have been updated between cycles.)

  ## 3. Spawn fresh verifier
  Use the verifier spawn template with added context:
    - {VERIFIER_DISCOVERY} = verifier_discovery (from baseline task metadata)
    - {BASELINE} = baseline failures
    - {PR_NUMBER} = current PR number
    - {CYCLE_NUMBER} = cycle_number

  ## 4. Spawn fresh reviewer
  Use the reviewer spawn template with added context:
    - {PR_NUMBER} = current PR number
    - {CYCLE_NUMBER} = cycle_number
    - {SPEC_REQUIREMENTS} = spec requirements section content
    - {SPEC_ACCEPTANCE_CRITERIA} = spec acceptance criteria section content

  ## 5. Spawn fresh builders (one per incomplete partition)
  For each partition where status not in ("completed", "needs_human"):
    Use the builder spawn template with:
      - {CYCLE_NUMBER} = cycle_number
      - {MAX_OUTER_CYCLES} = MAX_OUTER_CYCLES
      - {ITERATION_BUDGET} = partition.iteration_budget or MAX_BUILDER_ITERATIONS
      - {PREVIOUS_FINDINGS_OR_EMPTY} = reviewer_findings_by_builder[partition.builder_name]
      - {DONE_CONTRACT} = done_contracts[partition.builder_name] or "None"
      - {CONTRACT_CONTENT} = contract_content
      - {BUILDER_WORKTREE} = partition.builder_worktree (same worktree, fresh agent)

  ## 6. Wait for all fresh agents to report ready
```

## TSV Progress Log

The orchestrator maintains `tim-loop-results.tsv` in the integration worktree.
This provides visibility into the loop's progress and enables pattern recognition.

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

The `start_ts` and `end_ts` columns use ISO 8601 UTC format. The orchestrator records
`start_ts` when creating each phase task and `end_ts` when reading the completed task
metadata. Timestamps are captured from the system clock, not by running shell commands.

The `metric` column contains the feature metric value (from `## Verify Command`) when
metric_mode == "metric", or a pass/fail count when metric_mode == "pass_fail".

## Orchestrator Iron Laws

1. **Delegate everything.** Never read files, run commands, or analyze output. Agents do all work.
2. **Tasks are the state machine.** Create tasks with dependencies, read task metadata for decisions.
3. **Never skip phases.** ARCHITECT -> CONTRACT_NEGOTIATION (cycle 1, MANDATORY — do NOT skip) -> BUILD (keep/discard) -> INTEGRATE -> VERIFY (guard + feature + integration completeness) -> PUBLISH -> REVIEW. Always. The Orion retro showed that skipping contract negotiation allowed semantic errors to propagate unchallenged through the entire pipeline.
4. **Abort on NEEDS_HUMAN.** Immediately. No retries (except radical rethink for stagnant builders).
5. **Escalate before aborting.** On builder stagnation: try radical rethink once before marking NEEDS_HUMAN.
6. **Preserve resume state on abort.** Always write `.tim-loop-resume.json` with per-partition state and worktree paths.
7. **Route by file ownership.** Fix tasks and review findings go to the builder that owns the relevant files. Unroutable items go to builder-1.
8. **Respect backward compatibility.** Single partition = single builder named "builder" with a single builder worktree, no scope restrictions.
9. **Guard before feature.** Guard check failures (regressions) always trigger immediate revert. Feature metric changes trigger keep/discard.
10. **Log everything to TSV.** Every builder iteration, every integration attempt, every verification result.
11. **Typed message filtering.** After a builder's build task is completed, suppress status/progress/idle messages from that builder. ALWAYS process escalation messages (prefixed QUESTION:, NEEDS_HUMAN:, SCOPE_CONFLICT:, CONTRACT_ISSUE:) regardless of task status. Builders remain alive — if integration fails, assign a fix task to the existing builder.
12. **Route cross-partition integration fixes to reviewer.** Dead exports, missing imports, or connection failures that span partition boundaries go to the reviewer (who has the integration worktree), not to builders (who can only see their own partition).

## Progress Reporting

One line per phase transition:
- "Architect approved. Creating 3 builder worktrees..."
- "Cycle 1/3: Build complete (builder-1: 5 keeps/2 discards, builder-2: 3 keeps/0 discards)..."
- "Cycle 1/3: Integrating builder branches..."
- "Cycle 1/3: Guards PASS. Feature verify PASS. Running integration completeness..."
- "Cycle 1/3: Integration completeness: 0 stubs, 0 dead exports, 3/3 journeys PASS."
- "Cycle 1/3: Integration verify PASS. Metric: 72.3 → 85.1 (+12.8). Publishing..."
- "Cycle 1/3: Integration completeness FAIL: 2 stubs, 1 dead export, 1/3 journeys. Routing fixes..."
- "Cycle 1/3: Builder-2 hit 5 discards. Attempting radical rethink..."
- "Cycle 1/3: Review PASS (CI: 4/4 green). PR #47 ready for human review."
- "Cycle 1/3: CI failing (2 check(s)). Routing to builders..."
- "Cycle 1/3: Review FAIL (1 blocking, 2 CI failures). Refreshing agents for cycle 2..."
- "Cycle 2/3: Build complete. Integrating..."

## Skill Dependencies

| Skill | Used By | Purpose |
|-------|---------|---------|
| superpowers:using-git-worktrees | orchestrator | Create isolated worktrees |
| superpowers:test-driven-development | builders | Strict TDD during build |
| superpowers:verification-before-completion | builders | Self-check before handoff |
| superpowers:requesting-code-review | reviewer | Review methodology foundation |
| superpowers:finishing-a-development-branch | orchestrator | Final cleanup after success |
| /browse (gstack) | verifier | Interactive browser verification (preferred) |
| playwright-cli | verifier | Interactive browser verification (fallback) |
| Context7 MCP | all agents | Verify dependency APIs |

**Browser tool selection:** The verifier uses `/browse` (gstack) when available, falls back to
`playwright-cli`, and respects the project's CLAUDE.md if it specifies a preferred tool.
Automated E2E test suites (Playwright tests, Cypress, etc.) are always run directly
regardless of which interactive browser tool is used.

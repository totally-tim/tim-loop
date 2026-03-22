---
name: tim-loop
description: Use when you have a feature spec and want to automatically build, verify, and review it in an isolated worktree with a multi-agent team
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
echo '.tim-loop-contract.md' >> <integration-worktree>/.git/info/exclude
echo '.tim-loop-resume.json' >> <integration-worktree>/.git/info/exclude
echo 'tim-loop-results.tsv' >> <integration-worktree>/.git/info/exclude
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
- `tim-verify.md` — verification strategy reference

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
- Other placeholders filled as the loop progresses

The architect will study the codebase and produce the implementation contract.
The verifier will identify available test runners and frameworks.
The reviewer will study the codebase as part of its initial turn.

Wait for all 3 agents to report ready before proceeding to the Architect Phase.

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
   If not: reject with specific feedback (SendMessage type: plan_approval_response, approve: false).
   If acceptable: approve (approve: true).

4. Read the approved contract. Extract:
   - `partitions` — array of { name, files, requirements, dependencies }
   - `contract_content` — full text of .tim-loop-contract.md
   - `partition_count` — number of partitions
   - `connections_map` — the `## Connections` section content (for verifier Phase 3c)

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
        discovery: {
          test_runner: 'vitest',
          test_command: 'npm test',
          lint_command: 'npm run lint',
          typecheck_command: 'npx tsc --noEmit',
          build_command: 'npm run build',
          frameworks: ['vitest', 'eslint', 'typescript']
        }
      }"
  owner: verifier
```

Wait for verifier to complete this task.

Record the baseline, baseline_metric, AND the verifier discovery.

Initialize the TSV progress log:

```
## Write header + baseline row to tim-loop-results.tsv in integration worktree
cycle\tbuilder\titeration\tmetric\tguard\tstatus\tdescription
0\t-\t0\t{baseline_metric}\tpass\tbaseline\tinitial state
```

## THE LOOP

```
outer_cycle = 1
pr_number = null
baseline = (from Step 6, or empty if skipped)
baseline_metric = (from Step 6 task metadata, or null)
verifier_discovery = (from Step 6 task metadata, or empty if skipped)
metric_history_per_builder = {}  // map: builder_name -> list of {metric, status}
discard_streak_per_builder = {}  // map: builder_name -> consecutive discard count

while outer_cycle <= MAX_OUTER_CYCLES:

  ## 1. BUILD (with keep/discard iteration per builder)
  Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Starting build ({partition_count} builder(s))..."

  if outer_cycle == 1 and REQUIRE_PLAN_APPROVAL:
    ## PLAN APPROVAL was already handled in the Architect Phase (Step 5b).
    pass

  ## Create parallel build tasks — one per partition
  build_task_ids = []
  for partition in partitions:
    if partition.status == "needs_human":
      continue
    task = TaskCreate:
      subject: "Build partition: {partition.name} (cycle {outer_cycle})"
      description: |
        You are building partition "{partition.name}" in your isolated worktree.
        Worktree path: {partition.builder_worktree}
        Your file scope: {partition.files}
        Your requirements: {partition.requirements}
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

        Max iterations: {MAX_BUILDER_ITERATIONS}
        Report each iteration outcome in task metadata as it happens:
          metadata.iterations: [{metric: N, guard: "pass"|"fail", status: "keep"|"discard"|"revert", description: "..."}]

        When all requirements are implemented (or max iterations reached),
        mark this task complete with final metadata:
          metadata: { final_metric: N, iterations_used: M, keeps: K, discards: D }

        {If cycle 2+: "Incorporate findings for your partition: {partition_findings}"}
      owner: {partition.builder_name}

    build_task_ids.append(task.id)

  ## Wait for ALL builders to complete their build tasks.
  Wait for all tasks in build_task_ids to reach "completed" status.

  ## Read iteration results from each builder's task metadata
  for partition in partitions:
    if partition.status == "needs_human":
      continue
    task_meta = read_task_metadata(partition.build_task_id)
    iterations = task_meta.get("iterations", [])

    ## Track discard streaks for stuck detection
    consecutive_discards = 0
    for it in iterations:
      if it.status == "discard" or it.status == "revert":
        consecutive_discards += 1
      else:
        consecutive_discards = 0

    discard_streak_per_builder[partition.builder_name] = consecutive_discards

    ## Log to TSV
    for it in iterations:
      append_tsv_row(outer_cycle, partition.builder_name, it.iteration, it.metric, it.guard, it.status, it.description)

    ## Smart stuck detection (autoresearch-style escalation)
    if consecutive_discards >= 5:
      Tell user: "Builder {partition.builder_name} hit 5 consecutive discards."

      ## Instead of immediately aborting, give one radical rethink attempt
      if not partition.rethink_attempted:
        partition.rethink_attempted = true
        Tell user: "Attempting radical rethink for {partition.builder_name}..."

        TaskCreate:
          subject: "Radical rethink: {partition.name} (cycle {outer_cycle})"
          description: |
            You have hit 5 consecutive discards. Before giving up:
            1. Re-read the FULL spec from scratch
            2. Re-read the implementation contract
            3. Review your git log to see what you tried
            4. Try a FUNDAMENTALLY different approach:
               - If you were adding, try modifying existing code instead
               - If you were modifying, try a different file/module
               - Combine elements from your 2-3 best (closest to working) attempts
               - Try the OPPOSITE of your last approach
            5. Make ONE atomic change and verify
            Max 3 iterations for this rethink.
            Report outcome in task metadata.
          owner: {partition.builder_name}

        Wait for rethink task to complete.
        rethink_meta = read_task_metadata(rethink_task_id)

        if rethink_meta.get("status") == "success":
          Tell user: "Radical rethink succeeded for {partition.builder_name}."
          ## Continue to verify phase
        else:
          partition.status = "needs_human"
          Tell user: "Radical rethink failed. Marking {partition.name} as NEEDS_HUMAN."
          if not all_partitions_independent(partitions):
            ABORT("Builder {partition.builder_name} stagnant on dependent partition after rethink.")
      else:
        partition.status = "needs_human"
        Tell user: "Marking {partition.name} as NEEDS_HUMAN (rethink already attempted)."
        if not all_partitions_independent(partitions):
          ABORT("Builder {partition.builder_name} stagnant on dependent partition.")

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

  Wait for reviewer to complete integration task.
  Read integration metadata.

  if integration_metadata.merge_conflicts:
    ## Route conflict back to the conflicting builder
    conflicting_builder = integration_metadata.conflicting_builder
    Tell user: "Merge conflict from {conflicting_builder}. Routing resolution..."

    TaskCreate:
      subject: "Resolve merge conflict (cycle {outer_cycle})"
      description: |
        Your branch caused a merge conflict when integrating into the main branch.
        Conflicting files: {integration_metadata.files}
        Resolve the conflict in YOUR worktree by rebasing on the integration branch:
          git fetch origin
          git rebase tim-loop/{feature-slug}/integration
        Then re-verify with guard checks.
      owner: {conflicting_builder}

    Wait for resolution. Then retry integration from the conflicting builder onward.

  if integration_metadata.guard_status == "fail":
    ## Route guard failure to the builder whose merge broke it
    failed_builder = integration_metadata.failed_after_builder
    Tell user: "Guard failed after merging {failed_builder}. Routing fix..."
    ## Send fix task to that builder, re-attempt integration after fix

  ## 3. VERIFY INTEGRATION (three-phase)
  Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Verifying integrated build..."

  TaskCreate:
    subject: "Verify integrated build (cycle {outer_cycle})"
    description: |
      Verify the fully integrated build in the integration worktree.
      Integration worktree: {INTEGRATION_WORKTREE}
      Baseline failures (ignore these): {baseline}
      Baseline metric: {baseline_metric}

      Run THREE-PHASE verification:

      PHASE 1 — GUARD CHECK: Run all guard commands. ALL must pass.
        {GUARD_COMMANDS or "typecheck + lint + existing tests + build"}
        If any guard fails → FAIL immediately, skip Phase 2+3.

      PHASE 2 — FEATURE VERIFICATION: Run Tier 1-3 checks for new functionality.
        If metric_mode == "metric": Run verify command, extract metric value.
        PLAN ADHERENCE: Check implementation against spec requirements.
        If Phase 2 fails → FAIL, skip Phase 3.

      PHASE 3 — INTEGRATION COMPLETENESS (only if Phase 1+2 pass):
        3a. Stub/placeholder scan: grep diff for TODO, FIXME, empty functions, hardcoded mocks
        3b. Dead export detection: check new exports are actually imported somewhere
        3c. Connection verification using architect contract connections map:
            {CONNECTIONS_MAP}
        3d. User journey smoke tests (execute in browser):
            {USER_JOURNEYS}
            Take screenshots at each checkpoint as evidence.

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
  Read task metadata for: verdict, failure_keys, prognosis, feature_metric.

  ## Log integration verification to TSV
  append_tsv_row(outer_cycle, "integration", 0, feature_metric, guard_status, verdict, "integrated verify")

  if verdict == "PASS":
    Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Integration verify PASS."
    ## Proceed to publish

  elif verdict == "FAIL":
    if prognosis == "NEEDS_HUMAN":
      ABORT("Verifier reports issue needing human intervention.")

    ## Route failures to owning builders for fix
    Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Integration verify FAIL ({prognosis}). Routing fixes..."

    builder_failures = route_failures_to_builders(failure_keys, partitions)

    ## Each builder fixes in their own worktree, then we re-integrate
    fix_task_ids = []
    for builder_name, keys in builder_failures.items():
      task = TaskCreate:
        subject: "Fix integration failures for {builder_name} (cycle {outer_cycle})"
        description: |
          The integrated build failed. These failures are in your partition:
          {keys}
          Fix in your worktree using keep/discard discipline.
          The verifier sent you detailed findings via message.
          When fixed, mark this task complete.
        owner: {builder_name}
      fix_task_ids.append(task.id)

    Wait for all fix tasks to complete.
    ## Re-attempt integration from Step 2 (max 2 re-integration attempts per cycle)
    ## If still failing after 2 re-integrations, proceed to review with known issues

  ## 4. PUBLISH
  Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Publishing..."

  TaskCreate:
    subject: "Publish PR (cycle {outer_cycle})"
    description: |
      The integration branch is verified. Push and create/update PR.
      Integration worktree: {INTEGRATION_WORKTREE}
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

  ## 5. REVIEW
  Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Reviewing PR #{pr_number}..."

  TaskCreate:
    subject: "Review PR #{pr_number} (cycle {outer_cycle})"
    description: |
      Review PR #{pr_number} against the spec.
      Cycle {outer_cycle} of {MAX_OUTER_CYCLES}.
      Check every spec requirement. Use structured findings.
      Report verdict, prognosis, finding count, and findings in task metadata:
        metadata: { verdict: "PASS"|"FAIL", prognosis: "...", blocking_count: N, findings: [...] }
    owner: reviewer

  Wait for reviewer to complete review task.
  Read task metadata for: verdict, prognosis.
  reviewer_findings = task.metadata.findings

  if verdict == "PASS":
    Tell user: "Review PASS. PR #{pr_number} ready for human review."
    ## Log final state to TSV
    append_tsv_row(outer_cycle, "review", 0, feature_metric, "pass", "PASS", "review approved")
    Tell user final metrics summary if metric_mode == "metric":
      "Metric: {baseline_metric} → {feature_metric} ({metric_delta})"
    Invoke superpowers:finishing-a-development-branch
    CLEANUP_BUILDER_WORKTREES()
    SHUTDOWN_TEAM()
    DONE.

  elif verdict == "FAIL":
    if prognosis == "NEEDS_HUMAN":
      ABORT("Reviewer reports issue needing human intervention.")

    ## Route reviewer findings to relevant builders for next cycle
    reviewer_findings_by_builder = route_findings_to_builders(reviewer_findings, partitions)

    if outer_cycle < MAX_OUTER_CYCLES:
      Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Review FAIL. Refreshing agents for cycle {outer_cycle + 1}..."

      ## Refresh all agents before next cycle — fresh context windows
      REFRESH_AGENTS(
        cycle_number = outer_cycle + 1,
        reviewer_findings_by_builder,
        pr_number,
        baseline,
        partitions,
        contract_content,
        verifier_discovery
      )

      discard_streak_per_builder = {}

    outer_cycle += 1

// If we get here, all cycles exhausted
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
       "verifier_discovery": {
         "test_runner": "vitest",
         "test_command": "npm test",
         "lint_command": "npm run lint",
         "typecheck_command": "npx tsc --noEmit",
         "build_command": "npm run build",
         "frameworks": ["vitest", "eslint", "typescript"]
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
       "abort_reason": "Builder builder-2 stagnant after rethink."
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
REFRESH_AGENTS(cycle_number, reviewer_findings_by_builder, pr_number, baseline, partitions, contract_content, verifier_discovery):

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

  ## 5. Spawn fresh builders (one per incomplete partition)
  For each partition where status not in ("completed", "needs_human"):
    Use the builder spawn template with:
      - {CYCLE_NUMBER} = cycle_number
      - {MAX_OUTER_CYCLES} = MAX_OUTER_CYCLES
      - {MAX_BUILDER_ITERATIONS} = MAX_BUILDER_ITERATIONS
      - {PREVIOUS_FINDINGS_OR_EMPTY} = reviewer_findings_by_builder[partition.builder_name]
      - {CONTRACT_CONTENT} = contract_content
      - {BUILDER_WORKTREE} = partition.builder_worktree (same worktree, fresh agent)

  ## 6. Wait for all fresh agents to report ready
```

## TSV Progress Log

The orchestrator maintains `tim-loop-results.tsv` in the integration worktree.
This provides visibility into the loop's progress and enables pattern recognition.

Format:
```
cycle	builder	iteration	metric	guard	status	description
0	-	0	72.3	pass	baseline	initial state
1	builder-1	1	75.0	pass	keep	implemented auth endpoints
1	builder-1	2	75.0	fail	revert	broke existing tests
1	builder-1	3	78.2	pass	keep	auth endpoints with fixed imports
1	builder-2	1	72.3	pass	keep	added UI components
1	builder-2	2	72.3	pass	discard	metric unchanged after refactor
1	integration	0	80.5	pass	PASS	integrated verify
```

The `metric` column contains the feature metric value (from `## Verify Command`) when
metric_mode == "metric", or a pass/fail count when metric_mode == "pass_fail".

## Orchestrator Iron Laws

1. **Delegate everything.** Never read files, run commands, or analyze output. Agents do all work.
2. **Tasks are the state machine.** Create tasks with dependencies, read task metadata for decisions.
3. **Never skip phases.** ARCHITECT -> BUILD (keep/discard) -> INTEGRATE -> VERIFY (guard + feature + integration completeness) -> PUBLISH -> REVIEW. Always.
4. **Abort on NEEDS_HUMAN.** Immediately. No retries (except radical rethink for stagnant builders).
5. **Escalate before aborting.** On builder stagnation: try radical rethink once before marking NEEDS_HUMAN.
6. **Preserve resume state on abort.** Always write `.tim-loop-resume.json` with per-partition state and worktree paths.
7. **Route by file ownership.** Fix tasks and review findings go to the builder that owns the relevant files. Unroutable items go to builder-1.
8. **Respect backward compatibility.** Single partition = single builder named "builder" with a single builder worktree, no scope restrictions.
9. **Guard before feature.** Guard check failures (regressions) always trigger immediate revert. Feature metric changes trigger keep/discard.
10. **Log everything to TSV.** Every builder iteration, every integration attempt, every verification result.

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
- "Cycle 1/3: Review FAIL (1 blocking). Refreshing agents for cycle 2..."
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

---
name: tim-loop
description: Use when you have a feature spec and want to automatically build, verify, and review it in an isolated worktree with a multi-agent team
---

# Tim Loop — Automated Build-Verify-Review Loop

**Announce at start:** "I'm using the Tim Loop skill to run the automated build-verify-review loop."

## Overview

Tim Loop takes a feature spec (.md file) and runs an automated development loop:
1. Creates an isolated git worktree
2. Spawns a multi-agent team: architect (planning), N builders (parallel implementation), verifier, reviewer
3. Uses a shared task list for coordination — agents claim tasks, mark progress, and the user sees real-time status via `Ctrl+T`
4. Runs up to N outer cycles of build -> verify -> publish -> review (default 3)
5. Each verify step has up to M inner fix retries (default 5)
6. Ends with a PR ready for human review (or an abort with resume state)

You (the orchestrator) are a **thin coordinator**. You create tasks, assign them,
monitor task status, and make decisions. You NEVER read source files,
run tests, analyze diffs, or generate fix suggestions. Agents do all real work.

## Defaults (overridable via spec's `## Loop Config`)

| Setting | Default | Spec Override Key |
|---------|---------|-------------------|
| MAX_OUTER_CYCLES | 3 | `max_outer_cycles` |
| MAX_INNER_RETRIES | 5 | `max_inner_retries` |
| REQUIRE_PLAN_APPROVAL | true (cycle 1 only) | `require_plan_approval` |
| SKIP_BASELINE | false | `skip_baseline` |
| BUILDER_COUNT | auto | `builder_count` |
| MAX_BUILDERS | 5 | `max_builders` |

`builder_count: auto` means the architect agent decides based on codebase analysis.
Set to an integer to force a specific number of builders.
`max_builders` caps the architect's recommendation (safety valve for token costs).

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

If requirements lack priority tags, warn the user and default all to `[P0]`.

Extract the feature name from the `# Feature:` heading for use as team name slug.
Slugify: lowercase, replace spaces with hyphens, remove special characters.

### Step 2: Create Worktree

Invoke `superpowers:using-git-worktrees` to create an isolated branch.
All builder work happens in this worktree. Main branch stays untouched.
Record the `base_branch` (the branch HEAD was on before worktree creation).

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
- Other placeholders filled as the loop progresses

The architect will study the codebase and produce the implementation contract.
The verifier will identify available test runners and frameworks.
The reviewer will study the codebase as part of its initial turn.

Wait for all 3 agents to report ready before proceeding to the Architect Phase.

### Step 5b: Architect Phase

1. Create task for the architect:
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
   If not: reject with specific feedback (SendMessage type: plan_approval_response, approve: false).
   If acceptable: approve (approve: true).

4. Read the approved contract. Extract:
   - `partitions` — array of { name, files, requirements, dependencies }
   - `contract_content` — full text of .tim-loop-contract.md
   - `partition_count` — number of partitions

5. **Spawn builders:** For each partition, spawn a builder agent:
   ```
   Agent tool (general-purpose):
     name: "builder-{partition_index}" (or just "builder" if partition_count == 1)
     team_name: "{TEAM_NAME}"
     description: "Build: {partition_name}"
     mode: "bypassPermissions"
     prompt: (filled from tim-builder.md template with partition scope)
   ```

   When `partition_count == 1`: spawn a single builder named "builder" WITHOUT
   partition scope restrictions. This is backward-compatible with the current
   single-builder behavior.

   When `partition_count > 1`: spawn N builders, each named "builder-{index}",
   each with their partition scope (files, requirements) and the full contract
   embedded in their prompt.

6. Send `shutdown_request` to architect. Wait for confirmation.

7. Wait for all builders to report ready before starting the loop.

### Step 6: Baseline Verification (unless `skip_baseline` is true)

Create a task for the verifier to run all Tier 1 checks on the clean worktree
BEFORE the builder touches anything:

```
TaskCreate:
  subject: "Run baseline verification"
  description: "Run all Tier 1 checks (typecheck, lint, tests, build) on the
    clean worktree before any changes. Record which checks already fail.
    Report baseline as task metadata."
  owner: verifier
```

Wait for verifier to complete this task. The verifier stores baseline failures in
the task metadata as `{ baseline_failures: ["tier1/test/auth.test.ts:42", ...] }`.

Record the baseline. All subsequent verify tasks include this baseline so the
verifier can distinguish pre-existing failures from builder-introduced failures.

## THE LOOP

```
outer_cycle = 1
pr_number = null
baseline = (from Step 6, or empty if skipped)
failure_history_per_builder = {}  // map: builder_name -> list of failure_key sets

while outer_cycle <= MAX_OUTER_CYCLES:

  ## 1. BUILD
  Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Starting build ({partition_count} builder(s))..."

  if outer_cycle == 1 and REQUIRE_PLAN_APPROVAL:
    ## PLAN APPROVAL was already handled in the Architect Phase (Step 5b).
    ## The architect produced the plan and partitions. Builders do NOT
    ## go through a separate plan approval — they follow the contract.
    pass

  ## Create parallel build tasks — one per partition
  build_task_ids = []
  for partition in partitions:
    task = TaskCreate:
      subject: "Build partition: {partition.name} (cycle {outer_cycle})"
      description: |
        You are building partition "{partition.name}".
        Your file scope: {partition.files}
        Your requirements: {partition.requirements}
        Implementation contract: {contract_content}

        Create 3-6 granular sub-tasks for YOUR requirements only,
        ordered by priority (P0 first, then P1, then P2).
        Mark each sub-task complete as you finish it.
        When all sub-tasks are done, mark this parent task complete.
        {If cycle 2+: "Incorporate findings for your partition: {partition_findings}"}
      owner: {partition.builder_name}

    build_task_ids.append(task.id)

  ## Wait for ALL builders to complete their build tasks.
  ## Monitor via task status. If any builder sends NEEDS_HUMAN, handle immediately.
  Wait for all tasks in build_task_ids to reach "completed" status.
  Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: All {partition_count} builder(s) done. Starting verify..."

  inner_attempt = 1
  verified = false

  while inner_attempt <= MAX_INNER_RETRIES and not verified:

    ## 2. VERIFY
    Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Verify attempt {inner_attempt}/{MAX_INNER_RETRIES}..."

    TaskCreate:
      subject: "Verify build (cycle {outer_cycle}, attempt {inner_attempt})"
      description: |
        Verify the builders' work. Attempt {inner_attempt} of {MAX_INNER_RETRIES}.
        Baseline failures (ignore these): {baseline}
        {If inner_attempt > 1: "Previous failure keys: {previous_failure_keys}.
         Run previously-failed checks FIRST, then full suite if those pass."}
        Report verdict, failure_keys, and prognosis in task metadata:
          metadata: { verdict: "PASS"|"FAIL", failure_keys: [...], prognosis: "FIXABLE"|"NEEDS_HUMAN"|"UNCLEAR" }
        On FAIL: send detailed findings to ALL builders via SendMessage
        (each builder needs to see findings relevant to their partition).
      owner: verifier

    Wait for verifier to complete the verify task.
    Read task metadata for: verdict, failure_keys, prognosis.

    if verdict == "PASS":
      verified = true
      Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Verify PASS."

    elif verdict == "FAIL":

      if prognosis == "NEEDS_HUMAN":
        ABORT("Verifier reports issue needing human intervention.")

      ## 2b. FIX — Route failures to owning builders
      Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Verify FAIL ({inner_attempt}/{MAX_INNER_RETRIES}, {prognosis}). Routing fixes..."

      ## Route failure_keys to builders by file path
      builder_failures = {}  // map: builder_name -> [failure_keys]
      unroutable_failures = []

      for key in failure_keys:
        ## Extract file path from failure key (format: tier{N}/{check}/{identifier})
        ## The identifier typically contains a file path, e.g. "TS2345:src/payment.ts:42"
        file_path = extract_file_path(key)
        owning_builder = find_partition_owner(file_path, partitions)

        if owning_builder:
          builder_failures[owning_builder].append(key)
        else:
          unroutable_failures.append(key)

      ## Handle unroutable failures: assign to builder-1 (or the single builder)
      if unroutable_failures:
        builder_failures[partitions[0].builder_name].extend(unroutable_failures)

      ## Per-builder stagnation detection
      for builder_name, keys in builder_failures.items():
        if builder_name not in failure_history_per_builder:
          failure_history_per_builder[builder_name] = []
        failure_history_per_builder[builder_name].append(set(keys))

        history = failure_history_per_builder[builder_name]
        if len(history) >= 3:
          last_three = history[-3:]
          if last_three[0] == last_three[1] == last_three[2]:
            ## This builder is stagnant
            Tell user: "Builder {builder_name} stagnant — same failures 3x."
            partition = find_partition_by_builder(builder_name, partitions)
            if all_partitions_independent(partitions):
              partition.status = "needs_human"
              Tell user: "Marking partition {partition.name} as NEEDS_HUMAN. Other builders continue."
              del builder_failures[builder_name]  // remove from fix routing
            else:
              ABORT("Builder {builder_name} stagnant on dependent partition.")

      ## Create fix tasks only for builders with failures
      fix_task_ids = []
      for builder_name, keys in builder_failures.items():
        task = TaskCreate:
          subject: "Fix failures in {builder_name}'s partition (cycle {outer_cycle}, attempt {inner_attempt})"
          description: |
            Fix the issues reported by verifier in attempt {inner_attempt}.
            Your failure keys: {keys}
            The verifier sent you detailed findings via message.
            Only fix files within your partition scope.
            Mark complete when fixes are committed.
          owner: {builder_name}

        fix_task_ids.append(task.id)

      Tell user: "Routing {len(failure_keys)} failures to {len(builder_failures)} builder(s)..."

      Wait for all tasks in fix_task_ids to reach "completed" status.
      inner_attempt += 1

  if not verified:
    ABORT("Inner loop exhausted after {MAX_INNER_RETRIES} attempts.")

  ## 3. PUBLISH
  Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Publishing..."

  publisher = partitions[0].builder_name  // builder-1 or "builder" in single mode

  TaskCreate:
    subject: "Publish PR (cycle {outer_cycle})"
    description: |
      All builders have committed locally to the worktree branch.
      {If pr_number == null: "Push branch and create a new PR against {base_branch}.
       Include spec requirements as a checklist in the PR description.
       Mark P0/P1/P2 items with their priority. Check off completed items.
       Include requirements from ALL partitions, grouped by partition name."}
      {If pr_number != null: "Push updates to PR #{pr_number}.
       Update the PR description checklist with newly completed items."}
      Report the PR number and URL in task metadata:
        metadata: { pr_number: 47, pr_url: "https://..." }
    owner: {publisher}

  Wait for publisher to complete publish task.
  Read pr_number from task metadata.

  ## 4. REVIEW
  Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Reviewing PR #{pr_number}..."

  TaskCreate:
    subject: "Review PR #{pr_number} (cycle {outer_cycle})"
    description: |
      Review PR #{pr_number} against the spec.
      Cycle {outer_cycle} of {MAX_OUTER_CYCLES}.
      Check every spec requirement. Use structured findings.
      On FAIL: send detailed findings to ALL builders via SendMessage.
      Report verdict, prognosis, and finding count in task metadata:
        metadata: { verdict: "PASS"|"FAIL", prognosis: "...", blocking_count: N }
    owner: reviewer

  Wait for reviewer to complete review task.
  Read task metadata for: verdict, prognosis.

  if verdict == "PASS":
    Tell user: "Review PASS. PR #{pr_number} ready for human review."
    Invoke superpowers:finishing-a-development-branch
    SHUTDOWN_TEAM()
    DONE.

  elif verdict == "FAIL":
    if prognosis == "NEEDS_HUMAN":
      ABORT("Reviewer reports issue needing human intervention.")

    ## Route reviewer findings to relevant builders for next cycle
    reviewer_findings_by_builder = route_findings_to_builders(reviewer_findings, partitions)

    Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Review FAIL. Starting cycle {outer_cycle + 1}..."
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

2. **Preserve work and state:**
   - The worktree branch is NOT deleted
   - Write a resume state file to the worktree root:
     ```json
     // .tim-loop-resume.json
     {
       "team_name": "tim-loop-{feature-slug}",
       "spec_path": "/path/to/spec.md",
       "contract_path": ".tim-loop-contract.md",
       "base_branch": "main",
       "pr_number": 47,
       "outer_cycle": 2,
       "inner_attempt": 3,
       "partitions": [
         {
           "name": "auth-module",
           "builder_name": "builder-1",
           "files": ["src/auth/*", "tests/auth/*"],
           "requirements": ["[P0] JWT validation", "[P0] Session management"],
           "status": "completed",
           "last_failure_keys": [],
           "last_prognosis": null
         },
         {
           "name": "payment-module",
           "builder_name": "builder-2",
           "files": ["src/payments/*", "tests/payments/*"],
           "requirements": ["[P0] Payment processing", "[P1] Refund handling"],
           "status": "fixing",
           "last_failure_keys": ["tier1/test/payment.test.ts:42"],
           "last_prognosis": "FIXABLE"
         }
       ],
       "abort_reason": "Inner loop exhausted for partition payment-module."
     }
     ```
   - Tell user the branch name and resume file location
   - Tell user: "Run `/tim-loop --resume <worktree-path>` to continue."

3. **Shut down team:**
   - Send `shutdown_request` to all agents
   - Wait for confirmations
   - TeamDelete

## RESUME Procedure (when invoked with `--resume` or a `.tim-loop-resume.json` path)

1. Read the resume state file
2. Read the spec from `spec_path`
3. Read the contract from `contract_path` (already on disk in the worktree)
4. Create a new team (old agents are gone — no session resumption for teammates)
5. Spawn fresh verifier and reviewer agents
6. Spawn builders ONLY for partitions with status != "completed":
   - For each incomplete partition, spawn a builder with that partition's scope
   - Completed partitions do not need a builder
   - Do NOT re-spawn the architect — the contract is already on disk
7. Read the existing task list to see what was completed before the abort
8. Skip to the phase where the abort occurred:
   - If aborted during VERIFY: create a new verify task at the next attempt
   - If aborted during FIX: create fix tasks for the failing partitions
   - If aborted during REVIEW: start the next outer cycle
   - If all cycles exhausted: inform user, suggest manual intervention
   - If a partition was marked "needs_human": inform user which partition
     needs manual intervention and continue with remaining partitions
9. Continue the loop from there

## SHUTDOWN_TEAM Procedure

1. Send `shutdown_request` to ALL builders (builder-1, builder-2, ..., builder-N, or just "builder" in single mode)
2. Send `shutdown_request` to verifier and reviewer
3. Wait for all to confirm
4. Call TeamDelete to clean up team resources

## Orchestrator Iron Laws

1. **Delegate everything.** Never read files, run commands, or analyze output. Agents do all work.
2. **Tasks are the state machine.** Create tasks with dependencies, read task metadata for decisions. Counters tracked: cycle, attempt, failure_keys (per builder), prognosis, pr_number, partitions.
3. **Never skip phases.** ARCHITECT -> BUILD -> VERIFY -> PUBLISH -> REVIEW. Always.
4. **Abort on NEEDS_HUMAN.** Immediately. No retries.
5. **Abort on stagnation.** 3 consecutive identical failure_key sets per builder in inner loop = builder stagnant. Isolate if independent, abort if dependent.
6. **Preserve resume state on abort.** Always write `.tim-loop-resume.json` with per-partition state before shutting down.
7. **Route by file ownership.** Fix tasks and review findings go to the builder that owns the relevant files. Unroutable items go to builder-1.
8. **Respect backward compatibility.** Single partition = single builder named "builder" with no scope restrictions.

## Progress Reporting

One line per phase transition:
- "Architect approved. Spawning 3 builders..."
- "Cycle 1/3: Build complete (3/3 builders done). Starting verify..."
- "Cycle 1/3: Verify FAIL (attempt 2/5, FIXABLE). Routing fixes to 2 builder(s)..."
- "Cycle 1/3: Builder-2 stagnant. Marking partition as NEEDS_HUMAN."
- "Cycle 1/3: Verify PASS. Publishing PR..."
- "Cycle 1/3: Review FAIL (1 blocking). Routing findings to builder-1. Starting cycle 2..."
- "Cycle 2/3: Build complete. Starting verify..."

## Skill Dependencies

| Skill | Used By | Purpose |
|-------|---------|---------|
| superpowers:using-git-worktrees | orchestrator | Create isolated worktree |
| superpowers:test-driven-development | builders | Strict TDD during build |
| superpowers:verification-before-completion | builders | Self-check before handoff |
| superpowers:requesting-code-review | reviewer | Review methodology foundation |
| superpowers:finishing-a-development-branch | orchestrator | Final cleanup after success |
| playwright-cli | verifier | Browser automation for web verification |
| Context7 MCP | all agents | Verify dependency APIs |

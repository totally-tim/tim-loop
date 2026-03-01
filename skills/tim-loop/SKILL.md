---
name: tim-loop
description: Use when you have a feature spec and want to automatically build, verify, and review it in an isolated worktree with a multi-agent team
---

# Tim Loop — Automated Build-Verify-Review Loop

**Announce at start:** "I'm using the Tim Loop skill to run the automated build-verify-review loop."

## Overview

Tim Loop takes a feature spec (.md file) and runs an automated development loop:
1. Creates an isolated git worktree
2. Spawns a 3-agent team (builder, verifier, reviewer)
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
- `tim-builder.md` — builder agent prompt template
- `tim-verifier.md` — verifier agent prompt template
- `tim-reviewer.md` — reviewer agent prompt template
- `tim-verify.md` — verification strategy reference

### Step 5: Spawn Agents

Spawn all 3 agents using the Agent tool with `team_name` parameter:

For each agent, fill in the placeholders from their prompt template with:
- `{TEAM_NAME}` — the team name from Step 3
- `{FEATURE_NAME}` — from the spec heading
- `{SPEC_CONTENT}` — full spec text (embedded, not a file path)
- `{VERIFY_STRATEGY_CONTENT}` — full content of tim-verify.md
- `{SPEC_VERIFICATION_OVERRIDES_OR_NONE}` — from spec's `## Verification` section, or "None"
- `{OPEN_QUESTIONS}` — from spec's `## Open Questions` section, or "None"
- `{TEST_STRATEGY}` — from spec's `## Test Strategy` section, or "None"
- Other placeholders filled as the loop progresses

The builder and reviewer will study the codebase as part of their initial turn.
The verifier will identify available test runners and frameworks.

Wait for all 3 agents to report ready before starting the loop.

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

while outer_cycle <= MAX_OUTER_CYCLES:

  ## 1. BUILD
  Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Starting build..."

  if outer_cycle == 1 and REQUIRE_PLAN_APPROVAL:
    ## 1a. PLAN APPROVAL (cycle 1 only)
    TaskCreate:
      subject: "Plan build approach for {FEATURE_NAME}"
      description: |
        Study the codebase and create a build plan. Include:
        - Files to create/modify
        - Test approach (reference spec's Test Strategy if present)
        - Order of operations (P0 requirements first)
        - Open questions resolution (reference spec's Open Questions if present)
        Submit plan for orchestrator approval via ExitPlanMode.
      owner: builder

    Wait for builder to submit plan.
    Review the plan: check it covers all P0 requirements and addresses open questions.
    If acceptable: approve (SendMessage type: plan_approval_response, approve: true).
    If not: reject with feedback (approve: false, content: "...").
    After approval, the builder proceeds to create sub-tasks.

  TaskCreate:
    subject: "Build: {FEATURE_NAME} (cycle {outer_cycle})"
    description: |
      {cycle_context}
      Build the feature from the spec. Create 5-6 granular sub-tasks from
      requirements, ordered by priority (P0 first, then P1, then P2).
      Mark each sub-task complete as you finish it.
      When all sub-tasks are done, mark this parent task complete.
      {If cycle 2+: "Incorporate reviewer findings: {reviewer_findings}"}
    owner: builder

  Wait for builder to mark build task as completed.

  inner_attempt = 1
  verified = false
  failure_history = []  // list of failure_key sets for stagnation detection

  while inner_attempt <= MAX_INNER_RETRIES and not verified:

    ## 2. VERIFY
    Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Verify attempt {inner_attempt}/{MAX_INNER_RETRIES}..."

    TaskCreate:
      subject: "Verify build (cycle {outer_cycle}, attempt {inner_attempt})"
      description: |
        Verify the builder's work. Attempt {inner_attempt} of {MAX_INNER_RETRIES}.
        Baseline failures (ignore these): {baseline}
        {If inner_attempt > 1: "Previous failure keys: {previous_failure_keys}.
         Run previously-failed checks FIRST, then full suite if those pass."}
        Report verdict, failure_keys, and prognosis in task metadata:
          metadata: { verdict: "PASS"|"FAIL", failure_keys: [...], prognosis: "FIXABLE"|"NEEDS_HUMAN"|"UNCLEAR" }
        On FAIL: send detailed findings to builder via SendMessage.
      owner: verifier

    Wait for verifier to complete the verify task.
    Read task metadata for: verdict, failure_keys, prognosis.

    if verdict == "PASS":
      verified = true
      Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Verify PASS."

    elif verdict == "FAIL":

      if prognosis == "NEEDS_HUMAN":
        ABORT("Verifier reports issue needing human intervention.")

      ## Stagnation detection
      failure_history.append(failure_keys)
      if len(failure_history) >= 3:
        last_three = failure_history[-3:]
        if last_three[0] == last_three[1] == last_three[2]:
          ABORT("No progress after 3 fix attempts. Same failures recurring: {failure_keys}")

      ## 2b. FIX
      Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Verify FAIL ({inner_attempt}/{MAX_INNER_RETRIES}, {prognosis}). Builder fixing..."
      // Verifier already sent detailed findings to builder via SendMessage

      TaskCreate:
        subject: "Fix verify failures (cycle {outer_cycle}, attempt {inner_attempt})"
        description: |
          Fix the issues reported by verifier in attempt {inner_attempt}.
          Failure keys: {failure_keys}
          The verifier sent you detailed findings via message.
          Mark complete when fixes are committed.
        owner: builder

      Wait for builder to mark fix task as completed.
      inner_attempt += 1

  if not verified:
    ABORT("Inner loop exhausted after {MAX_INNER_RETRIES} attempts.")

  ## 3. PUBLISH
  Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Publishing..."

  TaskCreate:
    subject: "Publish PR (cycle {outer_cycle})"
    description: |
      {If pr_number == null: "Push branch and create a new PR against {base_branch}.
       Include spec requirements as a checklist in the PR description.
       Mark P0/P1/P2 items with their priority. Check off completed items."}
      {If pr_number != null: "Push updates to PR #{pr_number}.
       Update the PR description checklist with newly completed items."}
      Report the PR number and URL in task metadata:
        metadata: { pr_number: 47, pr_url: "https://..." }
    owner: builder

  Wait for builder to complete publish task.
  Read pr_number from task metadata.

  ## 4. REVIEW
  Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Reviewing PR #{pr_number}..."

  TaskCreate:
    subject: "Review PR #{pr_number} (cycle {outer_cycle})"
    description: |
      Review PR #{pr_number} against the spec.
      Cycle {outer_cycle} of {MAX_OUTER_CYCLES}.
      Check every spec requirement. Use structured findings.
      On FAIL: send detailed findings to builder via SendMessage.
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

    Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Review FAIL. Starting cycle {outer_cycle + 1}..."
    // Reviewer already sent findings to builder via SendMessage
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
       "base_branch": "main",
       "pr_number": 47,
       "outer_cycle": 2,
       "inner_attempt": 3,
       "last_failure_keys": ["tier1/test/payment.test.ts:42"],
       "last_prognosis": "FIXABLE",
       "abort_reason": "Inner loop exhausted after 5 attempts."
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
3. Create a new team (old agents are gone — no session resumption for teammates)
4. Spawn fresh agents with the spec
5. Read the existing task list to see what was completed before the abort
6. Skip to the phase where the abort occurred:
   - If aborted during VERIFY: create a new verify task at the next attempt
   - If aborted during REVIEW: start the next outer cycle
   - If all cycles exhausted: inform user, suggest manual intervention
7. Continue the loop from there

## SHUTDOWN_TEAM Procedure

1. Send `shutdown_request` to builder, verifier, reviewer
2. Wait for all to confirm
3. Call TeamDelete to clean up team resources

## Orchestrator Iron Laws

1. **Delegate everything.** Never read files, run commands, or analyze output. Agents do all work.
2. **Tasks are the state machine.** Create tasks with dependencies, read task metadata for decisions. Counters tracked: cycle, attempt, failure_keys, prognosis, pr_number.
3. **Never skip phases.** BUILD -> VERIFY -> PUBLISH -> REVIEW. Always.
4. **Abort on NEEDS_HUMAN.** Immediately. No retries.
5. **Abort on stagnation.** 3 consecutive identical failure_key sets in inner loop = no progress.
6. **Preserve resume state on abort.** Always write `.tim-loop-resume.json` before shutting down.

## Progress Reporting

One line per phase transition:
- "Cycle 1/3: Plan approved. Builder creating sub-tasks..."
- "Cycle 1/3: Build complete (6/6 sub-tasks done). Starting verify..."
- "Cycle 1/3: Verify FAIL (attempt 2/5, FIXABLE). Builder fixing..."
- "Cycle 1/3: Verify PASS. Publishing PR..."
- "Cycle 1/3: Review FAIL (1 blocking). Starting cycle 2..."
- "Cycle 2/3: Build complete. Starting verify..."

## Skill Dependencies

| Skill | Used By | Purpose |
|-------|---------|---------|
| superpowers:using-git-worktrees | orchestrator | Create isolated worktree |
| superpowers:test-driven-development | builder | Strict TDD during build |
| superpowers:verification-before-completion | builder | Self-check before handoff |
| superpowers:requesting-code-review | reviewer | Review methodology foundation |
| superpowers:finishing-a-development-branch | orchestrator | Final cleanup after success |
| playwright-cli | verifier | Browser automation for web verification |
| Context7 MCP | all agents | Verify dependency APIs |

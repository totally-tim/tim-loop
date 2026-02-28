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
3. Runs up to 3 outer cycles of build -> verify -> publish -> review
4. Each verify step has up to 5 inner fix retries
5. Ends with a PR ready for human review (or an abort with diagnostics)

You (the orchestrator) are a **thin coordinator**. You create tasks, assign them,
receive short status messages, and make decisions. You NEVER read source files,
run tests, analyze diffs, or generate fix suggestions. Agents do all real work.

## Constants

- **MAX_OUTER_CYCLES:** 3
- **MAX_INNER_RETRIES:** 5

## SETUP Phase

### Step 1: Load and Validate Spec

Read the spec file passed as argument. Validate it has:
- `## Goal` (non-empty)
- `## Requirements` (at least one item)
- `## Acceptance Criteria` (at least one item)

If validation fails, tell the user what's missing and stop.

Extract optional `## Verification` section content for spec overrides.

Extract the feature name from the `# Feature:` heading for use as team name slug.
Slugify: lowercase, replace spaces with hyphens, remove special characters.

### Step 2: Create Worktree

Invoke `superpowers:using-git-worktrees` to create an isolated branch.
All builder work happens in this worktree. Main branch stays untouched.

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

Spawn all 3 agents using the Task tool with `team_name` parameter:

For each agent, fill in the placeholders from their prompt template with:
- `{TEAM_NAME}` — the team name from Step 3
- `{FEATURE_NAME}` — from the spec heading
- `{SPEC_CONTENT}` — full spec text (embedded, not a file path)
- `{VERIFY_STRATEGY_CONTENT}` — full content of tim-verify.md
- `{SPEC_VERIFICATION_OVERRIDES_OR_NONE}` — from spec's ## Verification section, or "None"
- Other placeholders filled as the loop progresses

The builder and reviewer will study the codebase as part of their initial turn.
The verifier will identify available test runners and frameworks.

Wait for all 3 agents to report ready before starting the loop.

## THE LOOP

```
outer_cycle = 1
pr_number = null

while outer_cycle <= 3:

  ## 1. BUILD
  Tell user: "Cycle {outer_cycle}/3: Starting build..."
  Send message to builder with cycle context:
    - If cycle 1: "Build the feature from the spec."
    - If cycle 2+: Include reviewer findings from previous cycle.
  Wait for builder summary: "Build complete. {summary}"

  inner_attempt = 1
  verified = false

  while inner_attempt <= 5 and not verified:

    ## 2. VERIFY
    Tell user: "Cycle {outer_cycle}/3: Verify attempt {inner_attempt}/5..."
    Send message to verifier: "Verify the builder's work. Attempt {inner_attempt}."
    Wait for verifier verdict.

    if verdict == "PASS":
      verified = true
      Tell user: "Cycle {outer_cycle}/3: Verify PASS."

    elif verdict starts with "FAIL":
      Extract prognosis from verdict.

      if prognosis == "NEEDS_HUMAN":
        ABORT("Verifier reports issue needing human intervention.")

      ## 2b. FIX
      Tell user: "Cycle {outer_cycle}/3: Verify FAIL ({inner_attempt}/5, {prognosis}). Builder fixing..."
      // Verifier already sent details to builder directly
      Send message to builder: "Fix the issues reported by verifier. Attempt {inner_attempt}."
      Wait for builder: "Fix complete."
      inner_attempt += 1

      // Stagnation detection: if same failure 3 times in a row
      if inner_attempt >= 4 and no progress detected:
        ABORT("No progress after 3 fix attempts. Same failures recurring.")

  if not verified:
    ABORT("Inner loop exhausted after 5 attempts.")

  ## 3. PUBLISH
  Tell user: "Cycle {outer_cycle}/3: Publishing..."
  if pr_number == null:
    Send message to builder: "Push and create a new PR against {base_branch}."
  else:
    Send message to builder: "Push updates to PR #{pr_number}."
  Wait for builder to report PR URL.
  Extract pr_number from response.

  ## 4. REVIEW
  Tell user: "Cycle {outer_cycle}/3: Reviewing PR #{pr_number}..."
  Send message to reviewer with PR number and cycle context.
  Wait for reviewer verdict.

  if verdict starts with "PASS":
    Tell user: "Review PASS. PR #{pr_number} ready for human review."
    Invoke superpowers:finishing-a-development-branch
    SHUTDOWN_TEAM()
    DONE.

  elif verdict starts with "FAIL":
    Extract prognosis.
    if prognosis == "NEEDS_HUMAN":
      ABORT("Reviewer reports issue needing human intervention.")

    Tell user: "Cycle {outer_cycle}/3: Review FAIL. Starting cycle {outer_cycle + 1}..."
    // Reviewer already sent findings to builder directly
    outer_cycle += 1

// If we get here, all 3 cycles exhausted
Tell user: "3 cycles exhausted. PR #{pr_number} exists but has unresolved findings."
SHUTDOWN_TEAM()
```

## ABORT Procedure

When aborting for any reason:

1. **Tell the user:**
   - Which cycle/attempt failed
   - What the prognosis was
   - What the unresolved issues are (from last verifier/reviewer message)

2. **Preserve work:**
   - The worktree branch is NOT deleted
   - Tell user the branch name so they can resume manually

3. **Shut down team:**
   - Send `shutdown_request` to all agents
   - Wait for confirmations
   - TeamDelete

## SHUTDOWN_TEAM Procedure

1. Send `shutdown_request` to builder, verifier, reviewer
2. Wait for all to confirm
3. Call TeamDelete to clean up team resources

## Orchestrator Iron Laws

1. **Delegate everything.** Never read files, run commands, or analyze output. Agents do all work.
2. **Counters, not content.** Your state is: cycle, attempt, verdict, prognosis, pr_number.
3. **Never skip phases.** BUILD -> VERIFY -> PUBLISH -> REVIEW. Always.
4. **Abort on NEEDS_HUMAN.** Immediately. No retries.
5. **Abort on stagnation.** 3 identical failures in inner loop = no progress.

## Progress Reporting

One line per phase transition:
- "Cycle 1/3: Build complete. Starting verify..."
- "Cycle 1/3: Verify FAIL (attempt 2/5, FIXABLE). Builder fixing..."
- "Cycle 1/3: Verify PASS. Publishing PR..."
- "Cycle 1/3: Review FAIL (1 blocking). Starting cycle 2..."

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

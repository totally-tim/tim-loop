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
| CONTRACT_NEGOTIATION | if_needed | `contract_negotiation` |
| SKIP_BASELINE | false | `skip_baseline` |
| BUILDER_COUNT | auto | `builder_count` |
| MAX_BUILDERS | 5 | `max_builders` |
| METRIC_MODE | auto | `metric_mode` |
| MAX_REINTEGRATION_ATTEMPTS | monotonic | `max_reintegration_attempts` |

`builder_count: auto` means the architect agent decides based on codebase analysis.
Set to an integer to force a specific number of builders.
`max_builders` caps the architect's recommendation (safety valve for token costs).
`METRIC_MODE: auto` means: use metric-driven keep/discard if the spec has a `## Metric` section; fall back to pass/fail if not.

`CONTRACT_NEGOTIATION` modes:
- `off`: skip the propose-contract / review-contract step entirely. Builders read the
  architect's contract on first turn and proceed. Saves ~20K tokens per partition.
- `if_needed` (default): negotiate ONLY when the spec has `## Open Questions` that
  affect a specific partition OR any partition's `complexity: HIGH` AND uses a
  framework/library/pattern not already seen in the codebase. The orchestrator
  computes this from spec + architect contract before BUILD.
- `always`: legacy behavior — always negotiate on cycle 1.

The Spec 02 retro (Auth — Magic Link) measured negotiation as ~80K tokens of theater
across 4 builders with ~1 useful nudge in 15. The Orion retro showed that skipping
negotiation entirely allowed semantic errors to propagate. `if_needed` is the
reconciliation: negotiate when the spec or partition complexity genuinely demands
disambiguation; skip when the architect's contract already does the work.

`MAX_REINTEGRATION_ATTEMPTS` modes:
- `monotonic` (default): keep re-integrating as long as each attempt strictly reduces
  failure_keys count OR changes failure category (typecheck → build → runtime). Stop
  when two consecutive attempts produce the same failure_keys (no progress).
- A positive integer (e.g. `3`): legacy fixed cap.

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

### Step 2: Create Worktrees and Loop Directory

Create an **integration worktree** — this is the central branch where all work merges —
plus a `.tim-loop/` directory holding shared context files, per-phase state, and the
TSV results log. Everything under `.tim-loop/` is git-excluded; agents read it via
absolute path so files are visible from every builder worktree as well as the
integration worktree.

```bash
# Create integration worktree
git worktree add <worktree-base>/integration -b tim-loop/{feature-slug}/integration

# Exclude tim-loop artifacts from git tracking
# IMPORTANT: In a worktree, .git is a FILE (not a directory) containing "gitdir: <path>".
# We must resolve the actual gitdir path to find info/exclude.
WORKTREE_GITDIR=$(sed 's/^gitdir: //' < <integration-worktree>/.git)
mkdir -p "$WORKTREE_GITDIR/info"
echo '.tim-loop/' >> "$WORKTREE_GITDIR/info/exclude"
echo '.tim-loop-contract.md' >> "$WORKTREE_GITDIR/info/exclude"
echo '.tim-loop-resume.json' >> "$WORKTREE_GITDIR/info/exclude"
echo 'tim-loop-results.tsv' >> "$WORKTREE_GITDIR/info/exclude"

# Create the loop directory layout
mkdir -p <integration-worktree>/.tim-loop/context
mkdir -p <integration-worktree>/.tim-loop/state
```

Record the `base_branch` (the branch HEAD was on before worktree creation).
Record `loop_dir = <integration-worktree>/.tim-loop` — this is the root for context
files, phase artifacts, and resume state. All agents reference it via absolute path.

Builder worktrees are created LATER in Step 5b, after the architect defines partitions.

### Layout of `.tim-loop/`

```
<integration-worktree>/.tim-loop/
  context/
    spec.md                     # full spec content
    contract.md                 # symlink/copy of .tim-loop-contract.md (after architect)
    verify-strategy.md          # tim-verify.md content
    evaluation-calibration.md   # tim-evaluation-calibration.md content
    requirements.md             # extracted ## Requirements section
    acceptance-criteria.md      # extracted ## Acceptance Criteria
    compiler-traps.md           # extracted ## Compiler Traps
    connections.md              # extracted from contract ## Connections (after architect)
    partition-assignments.md    # partition→requirement mapping (after architect)
    user-journeys.md            # extracted ## User Journeys
  state/
    state.json                  # current orchestrator state (live)
    baseline.json               # baseline metric, failures, discovery
    build-{cycle}.json          # per-cycle build results
    integrate-{cycle}.json      # per-cycle integration results
    verify-{cycle}.json         # per-cycle verify results
    audit-{cycle}.json          # per-cycle audit results
    review-{cycle}.json         # per-cycle review results
  results.tsv                   # legacy progress log (kept for backward compat)
```

Agent prompts reference files in this directory via absolute path. Agents read the
files on their first turn; the prompts themselves embed only path references plus
per-spawn context that genuinely varies (partition scope, worktree path, cycle number).
This pattern replaces the previous "embed full spec/contract in every spawn" approach
and saves ~100-150K tokens per cycle on multi-builder runs.

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

### Step 4a: Spec Pre-flight Validation (BEFORE any agent spawn)

Before writing context files or spawning any agent, validate every command-shaped
string in the spec against the clean integration worktree. Catching a broken verify
command here costs ~5K tokens; catching it mid-loop costs ~80K.

For each of these spec sections, run the command in the integration worktree and
classify the result:

- `## Guards` — every guard command must exit 0 (or have a documented expected non-zero)
- `## Verify Command` — must execute, must produce output, must produce a number
  parseable as the metric. Run twice on the unmodified tree — values must be stable.
- Any command-shaped string in `## Verification` — same as Guards
- File path references in `## User Journeys` and `## Test Strategy` — files must exist
  (or be obviously about-to-be-created files matching architect's expected partitions)

**Hard fail on these violations** (tell user, abort before spawning):
- A guard command exits non-zero on the clean tree (the spec is wrong about the baseline)
- The verify command does not execute, errors out, or produces no number
- The verify command produces wildly inconsistent values across two consecutive runs
- A spec-referenced file path doesn't exist AND isn't a future-create candidate
- The verify command counts the wrong thing (e.g., counts files when the spec metric
  description says "tests"). Use the test runner's own count as the cross-check —
  if `pnpm test` reports 19 tests but the verify command outputs 5, the metric is wrong.

If a hard fail triggers, tell the user the exact issue, suggest the fix, and stop.
Do NOT proceed to baseline verification. The user updates the spec, re-invokes the loop.

**Soft warnings** (record in metadata, surface to user, continue):
- A spec section is empty when usually populated (e.g., no `## Guards`)
- A guard command takes >2 minutes (will slow every iteration)
- The verify command's sanity gate produces `metric_sanity != "ok"`

### Step 4b: Write Shared Context Files

Write the spec content and template-derived files to `<loop_dir>/context/` so agents
can read them via absolute path on their first turn. This replaces embedding the same
content in every agent spawn prompt.

```bash
LOOP_DIR=<integration-worktree>/.tim-loop
CONTEXT_DIR=$LOOP_DIR/context

# Full spec
cp <spec-path> $CONTEXT_DIR/spec.md

# Strategy and calibration files
cp ~/.claude/skills/tim-loop/tim-verify.md $CONTEXT_DIR/verify-strategy.md
cp ~/.claude/skills/tim-loop/tim-evaluation-calibration.md $CONTEXT_DIR/evaluation-calibration.md

# Extract sections from spec into separate files
# (orchestrator parses ## Requirements, ## Acceptance Criteria, ## Compiler Traps,
#  ## User Journeys from spec.md and writes to dedicated files. Empty section → write
#  the literal string "None" so agents can detect absence without missing-file errors.)
write $CONTEXT_DIR/requirements.md          (## Requirements section)
write $CONTEXT_DIR/acceptance-criteria.md   (## Acceptance Criteria section)
write $CONTEXT_DIR/compiler-traps.md        (## Compiler Traps section, or "None")
write $CONTEXT_DIR/user-journeys.md         (## User Journeys section, or "None")
```

Files derived later (after architect phase) are written in Step 5b:
- `contract.md` — symlink or copy of the architect's `.tim-loop-contract.md`
- `connections.md` — extracted `## Connections` section from contract
- `partition-assignments.md` — partition→requirement mapping

### Step 5: Spawn Initial Agents

Spawn the architect, verifier, and reviewer using the Agent tool with `team_name` parameter.
Builders are spawned LATER, after the architect produces partitions.

**Prompt-size discipline:** Most spawn-prompt placeholders are now PATHS into
`<loop_dir>/context/` and `<loop_dir>/state/` rather than full text. Each agent's
spawn prompt instructs it to read those files on the first turn. Only per-spawn
context that genuinely varies (worktree path, partition scope, cycle number) stays
inline. This keeps spawn prompts under ~5KB instead of ~50KB.

For each agent, fill in the placeholders from their prompt template with:

**Path placeholders (bulk-text content, agent reads on first turn):**
- `{LOOP_DIR}` — absolute path to `<integration-worktree>/.tim-loop/`
- `{CONTEXT_DIR}` — `{LOOP_DIR}/context/` (where spec, contract, strategy files live)
- `{STATE_DIR}` — `{LOOP_DIR}/state/` (where phase artifacts and live state live)

**Per-spawn inline placeholders (small, genuinely vary per agent):**
- `{TEAM_NAME}` — the team name from Step 3
- `{FEATURE_NAME}` — from the spec heading
- `{BUILDER_COUNT}` — from Loop Config, or "auto"
- `{MAX_BUILDERS}` — from Loop Config, or "5"
- `{METRIC_MODE}` — "metric" or "pass_fail"
- `{METRIC_COMMAND}` — from spec's `## Verify Command`, or "None"
- `{METRIC_DIRECTION}` — from spec's `## Metric` Direction field, or "None"
- `{GUARD_COMMANDS}` — from spec's `## Guards` section, or "None"
- `{INTEGRATION_WORKTREE}` — absolute path to the integration worktree
- `{BUILDER_WORKTREES}` — JSON map of partition_index → worktree path (after Step 5b)
- `{BUILDER_WORKTREE}` — single worktree path (per-builder spawn only)
- `{PARTITION_NAME}`, `{PARTITION_FILES}`, `{PARTITION_REQUIREMENTS}` — per-builder
- `{PARTITION_INDEX}` — per-builder
- `{PARTITION_COMPLEXITY}` — "NORMAL" or "HIGH"
- `{ITERATION_BUDGET}` — per-builder
- `{CYCLE_NUMBER}`, `{MAX_OUTER_CYCLES}` — per-cycle
- `{PR_NUMBER}` — once published
- `{PREVIOUS_FINDINGS_OR_EMPTY}` — fix-task content for refresh spawns
- `{DONE_CONTRACT}` — builder's negotiated done-contract from Step 0.5 (only when
  contract negotiation actually runs — see "Conditional Contract Negotiation" below)

**Removed embedded placeholders** (now read from `{CONTEXT_DIR}` instead):
- `{SPEC_CONTENT}` → agent reads `{CONTEXT_DIR}/spec.md`
- `{VERIFY_STRATEGY_CONTENT}` → agent reads `{CONTEXT_DIR}/verify-strategy.md`
- `{CONTRACT_CONTENT}` → agent reads `{CONTEXT_DIR}/contract.md`
- `{CONNECTIONS_MAP}` → agent reads `{CONTEXT_DIR}/connections.md`
- `{SPEC_REQUIREMENTS}` → agent reads `{CONTEXT_DIR}/requirements.md`
- `{SPEC_ACCEPTANCE_CRITERIA}` → agent reads `{CONTEXT_DIR}/acceptance-criteria.md`
- `{COMPILER_TRAPS}` → agent reads `{CONTEXT_DIR}/compiler-traps.md`
- `{USER_JOURNEYS}` → agent reads `{CONTEXT_DIR}/user-journeys.md`
- `{OPEN_QUESTIONS}`, `{TEST_STRATEGY}`, `{SPEC_VERIFICATION_OVERRIDES_OR_NONE}`
  → agent reads relevant section from `{CONTEXT_DIR}/spec.md`
- `{PARTITION_ASSIGNMENTS}` → agent reads `{CONTEXT_DIR}/partition-assignments.md`
- `{TOTAL_REQUIREMENT_COUNT}` → agent counts via reading the requirements file
- `{VERIFIER_DISCOVERY}` → agent reads `{STATE_DIR}/baseline.json` (when present)
- `{SPIKE_RESULTS}` → agent reads `{STATE_DIR}/spike-results.json` (when present)

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

Write spike results to `{STATE_DIR}/spike-results.json`. The architect reads this
file on its first turn — see tim-architect.md Context Files. The contract is then
based on verified behavior, not assumptions.

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
   - `partition_count` — number of partitions
   - `partition_assignments` — formatted string mapping each partition to its requirements (for auditor subagent dispatch)
   - `total_requirement_count` — count of all requirements + acceptance criteria (for auditor adaptive threshold)
   - `connections_map` — the `## Connections` section content (for verifier Phase 3c)

   For each partition, parse `iteration_budget` if present:
   - `partition.iteration_budget = min(parsed_value, MAX_BUILDER_ITERATIONS)`
   - If not specified: `partition.iteration_budget = MAX_BUILDER_ITERATIONS`

   **Write contract artifacts to context dir** (do this BEFORE spawning builders so
   they can read on first turn):
   ```bash
   cp <integration-worktree>/.tim-loop-contract.md $CONTEXT_DIR/contract.md
   write $CONTEXT_DIR/connections.md         (extracted ## Connections section)
   write $CONTEXT_DIR/partition-assignments.md  (formatted partition→requirement map)
   ```

   **Stub-shape lint** (before approving contract): For every shared contract file
   the architect wrote, check that any per-partition stubs reference the same exports
   with matching signatures. If a partition's stub declares `function foo(x: A): B`
   but the architect's shared contract declares `function foo(x: A, y: C): B`, REJECT
   with feedback. This catches ~80% of "stub said X, real impl said Y" bugs at
   contract-review time, before any builder iterates against the wrong shape.

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
          browser_tool: 'claude-in-chrome'  // or 'playwright-cli' | null
        }
      }"
  owner: verifier
```

Wait for verifier to complete this task.

Record the baseline, baseline_metric, AND the verifier discovery.

**Write baseline artifact to state dir:**
```bash
write $STATE_DIR/baseline.json {
  baseline_failures: [...],
  baseline_metric: 72.3,
  metric_sanity: "ok" | "warning: ...",
  discovery: { test_runner, test_command, lint_command, typecheck_command, build_command, frameworks, browser_tool }
}
```

**Metric sanity is a HARD GATE** (was previously advisory). If `metric_sanity` starts
with "warning", abort the loop with a clear message:

```
Tell user: "Spec metric is broken: {baseline_task_metadata.metric_sanity}.
This is a spec authoring issue — please fix the ## Verify Command and re-run.
The verify command must produce a number that meaningfully tracks the spec's metric."
ABORT.
```

**Why hard gate:** A wrong metric command silently misleads the keep/discard loop and
auditor evidence. The Spec 02 retro showed three iterations wasted before the verifier
caught a `grep -c` counting files instead of test cases. Catching this at baseline
costs ~5K tokens; trusting it costs ~30K+ across the loop.

If the user has a reason to proceed despite the warning (e.g., deliberately uses files
as the metric), they must update the spec to make the metric description match the
verify command output, then re-invoke the loop.

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

  ## 0.5. CONTRACT NEGOTIATION (conditional — see CONTRACT_NEGOTIATION mode)
  ##
  ## Decide whether to negotiate based on the configured mode and spec/partition state.
  ## Default: if_needed. Negotiate ONLY when the spec or partitions genuinely demand
  ## disambiguation. The Spec 02 retro measured negotiation as ~80K tokens with ~1 useful
  ## signal in 15; the Orion retro showed it's necessary when ambiguity affects a partition.
  ## "if_needed" is the reconciliation.

  needs_negotiation = false
  negotiation_reasons = []

  if CONTRACT_NEGOTIATION == "always":
    needs_negotiation = true
    negotiation_reasons = ["mode=always"]

  elif CONTRACT_NEGOTIATION == "if_needed" and outer_cycle == 1:
    ## Trigger 1: Open Questions in the spec that affect a partition.
    if spec has non-empty ## Open Questions:
      ## Match each open question against partition file scopes. If any question
      ## references files/topics owned by a specific partition, that partition needs
      ## negotiation.
      for question in open_questions:
        owning_partition = match_question_to_partition(question, partitions)
        if owning_partition:
          needs_negotiation = true
          negotiation_reasons.append(f"open question '{question[:60]}' affects {owning_partition.name}")

    ## Trigger 2: HIGH partition using a novel framework/pattern.
    ## Novel = the architect contract's implementation notes reference a library or
    ## pattern not already used in the existing codebase (e.g., Auth.js v5 in a repo
    ## that has no prior auth library). The orchestrator detects this by comparing
    ## the contract's listed libraries against `package.json` (or equivalent) in the
    ## integration worktree. New library names that don't already appear as direct
    ## dependencies count as novel.
    for partition in partitions:
      if partition.complexity == "HIGH":
        novel = detect_novel_libraries(partition, integration_worktree)
        if novel:
          needs_negotiation = true
          negotiation_reasons.append(f"HIGH partition '{partition.name}' uses novel: {novel}")

  if not needs_negotiation:
    Tell user: f"Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Skipping contract negotiation (mode={CONTRACT_NEGOTIATION}, no triggers fired). Building directly."
    done_contracts = {}  ## empty — verifier will not check done-contract adherence
    ## Skip to BUILD phase.

  else:
    Tell user: f"Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Contract negotiation triggered ({', '.join(negotiation_reasons)}). Negotiating done-contracts..."

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

      Your done-contract (if negotiation ran):
      {done_contracts[partition.builder_name] or "No done-contract (negotiation skipped — proceed using the architect contract directly)"}

      Architect contract: read {CONTEXT_DIR}/contract.md on first turn (already loaded as part of your spawn-prompt context-file instructions).

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
      Then perform any contract-declared post-merge handoffs (stub-replacements,
      path-rewrites) and run guards a SECOND time after the handoffs complete.
      Integration worktree: {INTEGRATION_WORKTREE}

      ## Stage A — Sequential merges

      For each builder (in order of partition index):
        1. cd {INTEGRATION_WORKTREE}
        2. git merge tim-loop/{feature-slug}/builder-{index} --no-edit
        3. If merge conflict:
           - Report which files conflict
           - Report which builder's changes caused the conflict
           - Set metadata: { merge_conflict: true, conflicting_builder: "builder-{N}", files: [...] }
           - Mark task as completed (orchestrator handles routing)
        4. After each successful merge, run per-merge guard checks:
           - {GUARD_COMMANDS or "typecheck + lint + existing tests + build"}
           - If guard fails after a merge, record which builder's merge broke it

      ## Stage B — Post-merge handoff (if declared in contract)

      If the architect contract's ## Connections section declares any post-merge
      handoff (path rewrites, stub-replacement sed, file moves), execute each
      handoff exactly as declared, in declared order. Commit the handoff result
      with message `chore: post-merge handoff (cycle {outer_cycle})`.

      The handoff is the failure mode the Spec 02 retro identified: per-merge guards
      pass, the sed-rewrite runs, then compilation breaks because stubs and real
      impls diverged. Stage C catches this BEFORE we waste a verify cycle on it.

      ## Stage C — POST-HANDOFF-GUARD (non-negotiable, runs even if no handoff)

      Re-run the FULL guard suite after the handoff stage:
      - {GUARD_COMMANDS or "typecheck + lint + existing tests + build"}

      Run guards even if Stage B was a no-op — verifies that the integrated state
      compiles end-to-end, not just each individual merge.

      If any guard fails:
        - Identify the offending file/import. Determine which builder owns it
          (by partition file scope).
        - Set metadata: {
            post_handoff_guard_status: "fail",
            post_handoff_failure_keys: [...],
            offending_builder: "builder-N",
            handoff_applied: true|false
          }
        - Mark task as completed (orchestrator routes the fix).

      ## On success

      After ALL merges succeed AND Stage B completes AND Stage C guards pass:
        - If metric_mode == "metric": run verify command, record integrated metric
        - Report in metadata: {
            merge_conflicts: false,
            per_merge_guard_status: "pass",
            post_handoff_guard_status: "pass",
            handoff_applied: true|false,
            failed_after_builder: null,
            integrated_metric: N
          }
    owner: reviewer

  Wait for reviewer to complete integration task. Read integration metadata.

  ## Write integrate artifact to state dir for this cycle
  write $STATE_DIR/integrate-{outer_cycle}.json (integration_metadata)

  if merge_conflicts:
    Route conflict to the conflicting builder with a resolve task (rebase on integration).
    Wait for resolution. Retry integration from the conflicting builder onward.

  if per_merge_guard_status == "fail":
    Route guard failure to the builder whose merge broke it (failed_after_builder).
    Send fix task to that builder, re-attempt integration after fix.

  if post_handoff_guard_status == "fail":
    ## NEW: handle post-handoff guard failures separately from per-merge failures.
    ## These are stub-vs-real-impl divergence bugs that per-merge guards missed.
    Route post_handoff_failure_keys to offending_builder (by file ownership).
    Send fix task with subject "Post-handoff guard fix (cycle {outer_cycle})".
    Wait for fix, then re-attempt integration from Stage A onward.

  ## Monotonic-progress re-integration loop
  ##
  ## Track failure_keys across re-integration attempts within this cycle.
  ## Default mode = "monotonic": continue while progress is strict; stop on stagnation.
  ## If MAX_REINTEGRATION_ATTEMPTS is an integer: use it as a fixed cap (legacy).

  reintegration_history = []  ## list of {attempt, failure_keys_set, category}
  attempt = 0
  while integration failed:
    attempt += 1
    reintegration_history.append({
      attempt: attempt,
      failure_keys_set: set(current_failure_keys),
      category: classify(current_failure_keys)  ## "typecheck" | "build" | "test" | "runtime"
    })

    if MAX_REINTEGRATION_ATTEMPTS is an integer and attempt >= MAX_REINTEGRATION_ATTEMPTS:
      Tell user: f"Hit fixed re-integration cap ({MAX_REINTEGRATION_ATTEMPTS}). Proceeding to VERIFY with known issues."
      break

    if MAX_REINTEGRATION_ATTEMPTS == "monotonic" and attempt >= 2:
      prev = reintegration_history[-2]
      curr = reintegration_history[-1]
      if prev.failure_keys_set == curr.failure_keys_set:
        Tell user: f"Re-integration stagnant: same {len(curr.failure_keys_set)} failure_keys two attempts running. Escalating."
        ABORT or REFRESH per existing policy.
      ## Progress check: failure count must strictly decrease OR category must change.
      strict_progress = (len(curr.failure_keys_set) < len(prev.failure_keys_set)) or (curr.category != prev.category)
      if not strict_progress:
        Tell user: f"Re-integration not making strict progress (attempt {attempt}). Categorizing as stagnant."
        ABORT or REFRESH per existing policy.

    ## Route the current failures to the relevant builders (see Failure-Key Routing Matrix below).
    ## Wait for fix tasks. Re-attempt integration.

  ## 3. VERIFY + AUDIT (parallel — BOTH run BEFORE publish)
  ##
  ## NOTE (changed from previous skill): the auditor now runs in parallel with the
  ## verifier, BEFORE publish. The Spec 02 retro caught BLOCKING auditor findings
  ## after PR was already up, forcing force-push cycles. Running both before publish
  ## ensures the PR only goes up once it's actually clean.
  ##
  ## REVIEW phase is now CI + code quality only (post-publish).

  Tell user: "Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Verifying integrated build (verifier + auditor in parallel)..."

  ## Spawn auditor just-in-time (fresh context window for deep spec read)
  Agent tool (general-purpose):
    name: "auditor"
    team_name: "{TEAM_NAME}"
    description: "Audit: {FEATURE_NAME}"
    mode: "bypassPermissions"
    prompt: (filled from tim-auditor.md template — uses {CONTEXT_DIR} paths, no embedded spec)

  ## Create BOTH tasks in parallel — verifier handles guards/features/integration completeness,
  ## auditor handles deep spec source-read.
  TaskCreate (verifier task):
    subject: "Verify integrated build (cycle {outer_cycle})"
    description: |
      Verify the fully integrated build in the integration worktree.
      Integration worktree: {INTEGRATION_WORKTREE}
      Read baseline failures and discovery from {STATE_DIR}/baseline.json.

      Done-contracts: read from {STATE_DIR}/state.json done_contracts field.
      If empty (negotiation skipped), omit done_contract_adherence from metadata.

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
        3c. Connection verification using architect contract connections map at
            {CONTEXT_DIR}/connections.md
        3d. User journey smoke tests (execute in browser) — see {CONTEXT_DIR}/user-journeys.md
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
        prognosis: "FIXABLE"|"NEEDS_HUMAN"|"UNCLEAR",
        quality_scores: { functional_completeness, code_health, integration_coherence },
        score_rationale: { ... },
        plan_adherence: [ ... ],
        done_contract_adherence: [ ... ] | omitted if no negotiation
      }
      On FAIL: send detailed findings to relevant builders via SendMessage AND post a
      summary message back to the orchestrator (TaskUpdate may be lost if task IDs
      go stale — see Coordination Resilience below).
    owner: verifier

  TaskCreate (auditor task — parallel to verifier):
    subject: "Deep spec audit (cycle {outer_cycle}, pre-publish)"
    description: |
      Perform deep spec completeness audit in the integration worktree.
      Integration worktree: {INTEGRATION_WORKTREE}

      All context files are at {CONTEXT_DIR}/ — read them on first turn:
      - {CONTEXT_DIR}/requirements.md — full requirements list
      - {CONTEXT_DIR}/acceptance-criteria.md — acceptance criteria
      - {CONTEXT_DIR}/contract.md — architect contract
      - {CONTEXT_DIR}/connections.md — cross-partition connection map
      - {CONTEXT_DIR}/user-journeys.md — user journeys (or "None")
      - {CONTEXT_DIR}/partition-assignments.md — partition→requirement mapping

      For each requirement and acceptance criterion:
      1. Grep to find implementation → Read the source file → classify REAL/STUB/MISSING
      2. Grep to find tests → Read the test file → classify THOROUGH/SHALLOW/MISSING
      3. Trace integration wiring from entry point → classify WIRED/ORPHAN
         (only for features with User Journeys — skip for background jobs, webhooks, etc.)
      4. Score confidence: HIGH/MEDIUM/LOW
      5. Verify architect's shared contracts are imported by consuming partitions
      6. Trace entry-point reachability for new user-facing features

      Produce compliance_report (markdown table) for the eventual PR description.

      Report deep_audit, connection_audit, contract_usage, reachability,
      compliance_report, findings, summary, quality_scores, score_rationale in
      task metadata. POST RESULT VIA SendMessage TOO (resilience against task ID drift).
    owner: auditor

  Wait for BOTH tasks to complete (parallel).
  Read verifier metadata: verify_verdict, verify_failure_keys, verify_prognosis, feature_metric, plan_adherence, verifier_quality_scores, done_contract_adherence
  Read auditor metadata: audit_verdict, deep_audit, compliance_report, auditor_findings, auditor_quality_scores, reachability, contract_usage

  ## Write phase artifacts
  write $STATE_DIR/verify-{outer_cycle}.json (verifier metadata)
  write $STATE_DIR/audit-{outer_cycle}.json (auditor metadata)

  ## Cross-Agent Verification Triangulation (existing logic, run here pre-publish)
  if verifier's plan_adherence is available:
    for each requirement in deep_audit:
      verifier_entry = find matching requirement in plan_adherence
      if verifier_entry and verifier_entry.status == "IMPLEMENTED" and requirement.impl_status == "STUB":
        Tell user: "TRIANGULATION ALERT: Verifier grep-found '{requirement.requirement}' but auditor source-read assessed STUB."
        auditor_findings.append({
          severity: "BLOCKING",
          category: "triangulation-disagreement",
          description: "Verifier grep evidence vs auditor source-read: classified STUB. {requirement.impl_assessment}",
          requirement: requirement.requirement,
          builder: (route by file path of requirement.impl_file)
        })

  ## Done-contract adherence (existing logic, run here pre-publish)
  done_contract_failures = []
  if verifier metadata has done_contract_adherence:
    for item in done_contract_adherence:
      if item.status == "NOT_DELIVERED":
        done_contract_failures.append({
          severity: "BLOCKING",
          category: "done-contract-breach",
          description: f"Builder {item.builder} committed '{item.committed}' but did not deliver. Evidence: {item.evidence}",
          builder: item.builder
        })

  ## Combine verifier + auditor verdicts BEFORE publish.
  ## Both must PASS; quality scores from either side must all be >= 6.
  combined_findings = (verify_failure_keys mapped to findings) + auditor_findings + done_contract_failures

  all_scores = {**(verifier_quality_scores or {}), **(auditor_quality_scores or {})}
  all_rationale = {**(verifier_score_rationale or {}), **(auditor_score_rationale or {})}
  score_failures = [dim for dim, score in all_scores.items() if score < 6]

  if score_failures:
    Tell user: f"Quality score(s) below threshold: {score_failures}"
    for dim in score_failures:
      combined_findings.append({
        severity: "BLOCKING",
        category: "quality-score-below-threshold",
        description: f"{dim}: {all_scores[dim]}/10 — below threshold of 6. Rationale: {all_rationale[dim]}",
        builder: routing_for_dimension(dim)
      })

  ## Validate auditor's deep_audit before accepting any verdict
  if deep_audit is missing or empty:
    Tell user: "Auditor did not produce deep_audit. Treating as FAIL."
    pre_publish_verdict = "FAIL"
    prognosis = "FIXABLE"
  else:
    critical_gaps = [r for r in deep_audit
      if (r.priority == "P0" or r.priority == "AC")
      and (r.impl_status != "REAL" or r.test_status == "MISSING" or r.confidence == "LOW")]
    reachability_failures = [r for r in (auditor_findings or []) if r.category == "unreachable-feature"]
    contract_failures = [r for r in (auditor_findings or []) if r.category == "contract-unused"]
    all_blocking = critical_gaps + reachability_failures + contract_failures

    if verify_verdict == "FAIL" or all_blocking or score_failures:
      pre_publish_verdict = "FAIL"
      ## Pick the worst prognosis.
      if verify_prognosis == "NEEDS_HUMAN":
        prognosis = "NEEDS_HUMAN"
      else:
        prognosis = "FIXABLE"
      for gap in critical_gaps:
        combined_findings.append({
          severity: "BLOCKING",
          category: "auditor-p0-gap",
          description: f"P0/AC '{gap.requirement}': impl={gap.impl_status}, test={gap.test_status}, confidence={gap.confidence}",
          builder: route_by_file_path(gap.impl_file)
        })
    else:
      pre_publish_verdict = "PASS"

  ## Log verify+audit phase to TSV
  append_tsv_row(outer_cycle, "VERIFY+AUDIT", "integration", 0, feature_metric, "pass" if pre_publish_verdict=="PASS" else "fail", pre_publish_verdict, duration_s, start_ts, end_ts, "verify + audit (pre-publish)")

  if pre_publish_verdict == "PASS":
    Tell user: f"Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Verify+Audit PASS. Proceeding to publish."
    ## Proceed to publish

  elif pre_publish_verdict == "FAIL":
    if prognosis == "NEEDS_HUMAN":
      ABORT("Verify+Audit reports issue needing human intervention.")

    Tell user: f"Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Verify+Audit FAIL ({prognosis}). Routing fixes (NO publish yet)..."

    ## Route findings using the Failure-Key Routing Matrix (see below).
    ## Builders fix in their own worktrees, then INTEGRATE re-runs.
    ## Monotonic-progress rules from INTEGRATE phase apply here too — track failure_keys
    ## across pre-publish fix attempts within this cycle.

    Wait for all fix tasks to complete.
    Re-run INTEGRATE → VERIFY+AUDIT cycle. Honor monotonic-progress.
    Continue until pre_publish_verdict == "PASS" or stagnation triggers escalation.

  ## 4. PUBLISH (only after VERIFY+AUDIT PASS)
  Tell user: f"Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Publishing..."

  TaskCreate:
    subject: "Publish PR (cycle {outer_cycle})"
    description: |
      The integration branch passed VERIFY+AUDIT. Push and create/update PR.
      Integration worktree: {INTEGRATION_WORKTREE}

      ## Artifact Cleanup (do this FIRST, before pushing)

      Remove tim-loop artifacts from git tracking if they leaked in:
      ```bash
      cd {INTEGRATION_WORKTREE}
      git rm --cached --ignore-unmatch .tim-loop-contract.md .tim-loop-resume.json tim-loop-results.tsv 2>/dev/null
      # The .tim-loop/ directory is git-excluded so nothing inside it should be staged.
      git diff --cached --quiet || git commit -m "chore: remove tim-loop artifacts from tracking"
      ```

      ## Push and PR

      Compliance report (from auditor) is available at {STATE_DIR}/audit-{outer_cycle}.json
      (field: compliance_report). Include it in the PR description between
      `<!-- SPEC-COMPLIANCE-START -->` and `<!-- SPEC-COMPLIANCE-END -->` markers so
      idempotent updates work across cycles.

      {If pr_number == null: "Push the integration branch and create a new PR against {base_branch}.
       Include spec requirements as a checklist in the PR description.
       Mark P0/P1/P2 items with their priority. Check off completed items.
       Include requirements from ALL partitions, grouped by partition name.
       Include a metrics summary if metric_mode == 'metric':
         Baseline: {baseline_metric} → Final: {feature_metric} ({metric_delta})
       Include the compliance_report between SPEC-COMPLIANCE markers."}
      {If pr_number != null: "Push updates to PR #{pr_number}.
       For re-published cycles after a git reset on the integration branch, use:
         git push --force-with-lease origin tim-loop/{feature-slug}/integration
       (Never bare --force — --force-with-lease refuses if the remote moved.)
       Update the PR description checklist + the SPEC-COMPLIANCE section."}
      Report the PR number and URL in task metadata:
        metadata: { pr_number: 47, pr_url: "https://..." }
    owner: reviewer

  Wait for reviewer to complete publish task.
  Read pr_number from task metadata.

  ## 5. REVIEW (CI + code quality only, post-publish)
  ##
  ## NOTE: Spec completeness audit has already run pre-publish (see VERIFY+AUDIT).
  ## REVIEW is now CI + code quality only — auditor does not run here.

  Tell user: f"Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Reviewing PR #{pr_number} (CI + code quality)..."

  TaskCreate:
    subject: f"Review PR #{pr_number} (cycle {outer_cycle})"
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
      gh pr diff {PR_NUMBER} | grep -q '\.tim-loop-contract\.md\|\.tim-loop-resume\.json\|tim-loop-results\.tsv\|\.tim-loop/'
      ```
      If any match: BLOCKING finding (category: "artifact-in-diff", description: "{filename} is in the diff — the publish step should have cleaned this up").

      ## Code Review

      Review code quality using `gh pr diff`. Use structured findings.

      ## NOTE: Spec completeness already audited pre-publish. Do NOT re-audit here.
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
      Also post your final verdict via SendMessage to the orchestrator (resilience).
    owner: reviewer

  Wait for reviewer to complete review task.
  Read reviewer metadata: reviewer_verdict, reviewer_findings, ci_status, ci_checks

  ## Write review artifact
  write $STATE_DIR/review-{outer_cycle}.json (reviewer metadata)

  ## Final verdict — at this point VERIFY+AUDIT have already PASSED pre-publish.
  ## REVIEW only judges CI + post-publish code quality.
  combined_findings = reviewer_findings

  if reviewer_verdict == "PASS":
    final_verdict = "PASS"
  else:
    final_verdict = "FAIL"
    prognosis = reviewer_prognosis or "FIXABLE"

  if final_verdict == "PASS":
    Tell user: f"Review PASS (CI: {ci_checks.passed}/{ci_checks.total} green). PR #{pr_number} ready for human review."
    ## Log final state to TSV
    append_tsv_row(outer_cycle, "REVIEW", "review", 0, feature_metric, "pass", "PASS", duration_s, start_ts, end_ts, "review approved")
    if metric_mode == "metric":
      Tell user: f"Metric: {baseline_metric} → {feature_metric} ({metric_delta})"

    ## Write lessons artifact (cumulative, cross-run) before tearing down.
    WRITE_LESSONS_ARTIFACT(outer_cycle, success=true)

    Invoke superpowers:finishing-a-development-branch
    CLEANUP_BUILDER_WORKTREES()
    SHUTDOWN_TEAM()
    DONE.

  elif final_verdict == "FAIL":
    if prognosis == "NEEDS_HUMAN":
      ABORT("Review reports issue needing human intervention.")

    ## Route CI failures to builders using the Failure-Key Routing Matrix.
    ci_failures = [f for f in reviewer_findings if f.category in ("ci-failure", "ci-timeout")]
    if ci_failures:
      Tell user: f"Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: CI failing ({ci_checks.failed} check(s)). Routing to builders..."

    if outer_cycle < MAX_OUTER_CYCLES:
      Tell user: f"Cycle {outer_cycle}/{MAX_OUTER_CYCLES}: Review FAIL. Refreshing agents for cycle {outer_cycle + 1}..."
      REFRESH_AGENTS(cycle_number = outer_cycle + 1, combined_findings)

    outer_cycle += 1

// All cycles exhausted
Tell user: f"{MAX_OUTER_CYCLES} cycles exhausted. PR #{pr_number} exists but has unresolved findings."
WRITE_LESSONS_ARTIFACT(outer_cycle, success=false)
ABORT("All cycles exhausted.")
```

## Failure-Key Routing Matrix

Use this table to route findings without orchestrator guesswork. Routing keys on the
finding's `category` field (already populated by verifier/auditor/reviewer).

| Category | Default routing target | Notes |
|---|---|---|
| `guard/typecheck/{file}` | builder owning {file} | by partition file scope |
| `guard/lint/{file}` | builder owning {file} | |
| `guard/test/{file}` | builder owning {file} | existing-test regression |
| `guard/build/{path}` | builder owning {path} | if edge-bundle or app-entry: route to P1 / app-entry partition |
| `guard/launch/crash-on-startup` | app-entry partition | native apps |
| `tier1/test/{file}` | builder owning {file} | new-test failure |
| `tier2/playwright/{path}` | UI partition | |
| `tier3/{check}` | per spec verification override | |
| `defense/validation/{path}` | builder owning {path} | NON-BLOCKING by default |
| `defense/security/*` | builder owning the new data path | BLOCKING |
| `defense/atomicity/*` | builder owning the multi-step mutation | BLOCKING |
| `defense/consistency/*` | builder owning duplicated definition | NON-BLOCKING unless data corruption path |
| `plan/requirement-missing:{req}` | builder assigned that requirement (architect contract); if unassigned → architect re-review | |
| `integration/stub/{file}` | builder owning {file} | |
| `integration/dead-export/{file}:{export}` | if consumer in same partition → that builder; if cross-partition → reviewer | reviewer has the integration worktree |
| `integration/connection/A→B` | if A and B in same partition → that builder; else → reviewer | |
| `integration/wiring/{component}` | app-entry partition | |
| `integration/journey/{name}:{step}` | builder owning the failing route/handler | |
| `integration/protocol/{protocol}` | builder owning the shared protocol | |
| `auditor-p0-gap` (stub-impl, shallow-test) | builder owning the file via deep_audit's impl_file | |
| `contract-unused` | builder of the partition that should consume the contract | |
| `unreachable-feature` | builder owning the page/route registration | |
| `triangulation-disagreement` | builder owning impl_file (auditor's source-read source of truth) | |
| `done-contract-breach` | builder named in the breach | |
| `quality-score-below-threshold` | by dimension: `implementation_depth` / `test_thoroughness` → auditor's impl_file owners; `functional_completeness` / `integration_coherence` → verifier's failure_key owners; `code_health` / `spec_fidelity` → builder-1 default | |
| `ci-failure` (builder=null after log inspection) | builder-1 | |
| `ci-timeout` | not routed — escalate to user | |
| `artifact-in-diff` | not routed — reviewer cleans up in next publish | |

Routing is best-effort. When ambiguous, prefer to (a) route to the builder whose
partition scope matches the file path, then (b) route to the reviewer for cross-
partition fixes (since they own the integration worktree), then (c) default to
builder-1 with a note.

## WRITE_LESSONS_ARTIFACT Procedure

At the end of every cycle that reaches a terminal state (PASS or all cycles
exhausted), write a small lessons artifact so future runs can grep accumulated
patterns. Stored under `~/.claude/skills/tim-loop/lessons/` (not the worktree —
cumulative across runs and projects).

```
filename: ~/.claude/skills/tim-loop/lessons/{YYYY-MM-DD}-{feature-slug}.md
content:
  # Feature: {feature-name}
  Outcome: PASS | FAIL
  Cycles: {outer_cycle}
  Builders: {partition_count}
  Notable patterns:
    - things that worked first try
    - things that required rethink
    - framework-specific gotchas encountered (Auth.js edge-split, etc.)
  Architect-relevant traps (architect pre-flight should grep these):
    - one-line technical traps the architect should flag in future contracts
```

Keep entries short (<2KB). The architect's pre-flight (Step 5b) will grep this
directory for relevant framework names before writing its contract.

## ABORT Procedure

When aborting for any reason:

1. **Tell the user:**
   - Which cycle/attempt failed
   - What the prognosis was
   - What the unresolved issues are (from last verifier/reviewer task metadata)
   - Metrics summary if metric_mode == "metric"

2. **Preserve work and state:**
   - The worktree branches are NOT deleted
   - The `.tim-loop/state/` directory already contains the per-phase artifacts
     (baseline.json, integrate-N.json, verify-N.json, audit-N.json, review-N.json).
     On resume, the orchestrator reads these instead of re-running phases.
   - Write a top-level resume pointer at `.tim-loop-resume.json` (in the integration
     worktree root, NOT inside .tim-loop/) so the resume command can find the
     loop without traversing:
     ```json
     // .tim-loop-resume.json — pointer file, durable detail is under .tim-loop/state/
     {
       "team_name": "tim-loop-{feature-slug}",
       "spec_path": "/path/to/spec.md",
       "loop_dir": "/path/to/integration/.tim-loop",
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
         "browser_tool": "claude-in-chrome"
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
  Use the verifier spawn template with:
    - {CONTEXT_DIR}, {STATE_DIR} unchanged (files on disk persist across cycles)
    - {PR_NUMBER} = current PR number
    - {CYCLE_NUMBER} = cycle_number
  Baseline + discovery are read from {STATE_DIR}/baseline.json by the verifier itself.

  ## 4. Spawn fresh reviewer
  Use the reviewer spawn template with:
    - {CONTEXT_DIR}, {STATE_DIR} unchanged
    - {PR_NUMBER} = current PR number
    - {CYCLE_NUMBER} = cycle_number

  ## 5. Spawn fresh builders (one per incomplete partition)
  For each partition where status not in ("completed", "needs_human"):
    Use the builder spawn template with:
      - {CONTEXT_DIR}, {STATE_DIR} unchanged
      - {CYCLE_NUMBER} = cycle_number
      - {MAX_OUTER_CYCLES} = MAX_OUTER_CYCLES
      - {ITERATION_BUDGET} = partition.iteration_budget or MAX_BUILDER_ITERATIONS
      - {PREVIOUS_FINDINGS_OR_EMPTY} = reviewer_findings_by_builder[partition.builder_name]
      - {DONE_CONTRACT} = done_contracts[partition.builder_name] or "None"
      - {BUILDER_WORKTREE} = partition.builder_worktree (same worktree, fresh agent)
    The builder reads contract.md / spec.md / compiler-traps.md from {CONTEXT_DIR}/ on first turn.

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
2. **Tasks are the state machine, but state is also files.** Create tasks with dependencies, read task metadata for decisions. ALSO write durable per-phase state files to `{STATE_DIR}/` (baseline.json, integrate-N.json, verify-N.json, audit-N.json, review-N.json) so the loop survives task-ID drift, mid-run aborts, and resume.
3. **Phase order is fixed; contract negotiation is conditional.** Phase order:
   SETUP (spec preflight) → ARCHITECT (with framework pre-flight) → CONTRACT_NEGOTIATION (conditional — see CONTRACT_NEGOTIATION mode) → BUILD (keep/discard) → INTEGRATE (per-merge guards + POST-HANDOFF-GUARD) → VERIFY+AUDIT (parallel, both pre-publish) → PUBLISH → REVIEW (CI + code quality post-publish).
   The Orion retro showed that always-skipping contract negotiation allowed semantic errors to propagate. The Spec 02 retro showed that always-running it produced ~80K tokens of theater. The reconciliation is `if_needed` mode: negotiate only when triggers fire (Open Questions affecting a partition, OR HIGH-complexity partition using novel libraries).
4. **Abort on NEEDS_HUMAN.** Immediately. No retries (except radical rethink for stagnant builders).
5. **Escalate before aborting.** On builder stagnation: try radical rethink once before marking NEEDS_HUMAN.
6. **Preserve resume state on abort.** Always write `.tim-loop-resume.json` with per-partition state and worktree paths. Also keep `{STATE_DIR}/state.json` live across normal operation.
7. **Route by failure-key category.** Use the Failure-Key Routing Matrix (see above). Files trump categories when both apply (file-path partition match wins).
8. **Respect backward compatibility.** Single partition = single builder named "builder" with a single builder worktree, no scope restrictions.
9. **Guard before feature.** Guard check failures (regressions) always trigger immediate revert. Feature metric changes trigger keep/discard.
10. **Log everything to TSV AND phase artifacts.** Every builder iteration, every integration attempt, every verification result. TSV is the timeline; JSON phase artifacts are the durable detail.
11. **Typed message filtering, and resilient acks.** After a builder's build task is completed, suppress status/progress/idle messages from that builder. ALWAYS process escalation messages (prefixed QUESTION:, NEEDS_HUMAN:, SCOPE_CONFLICT:, CONTRACT_ISSUE:) regardless of task status. When an agent's TaskUpdate fails (task ID went stale), accept the equivalent SendMessage as the verdict — agents are instructed to post both.
12. **Route cross-partition integration fixes to reviewer.** Dead exports, missing imports, or connection failures that span partition boundaries go to the reviewer (who has the integration worktree), not to builders (who can only see their own partition).
13. **Audit BEFORE publish, not after.** The auditor's deep source-read runs in parallel with the verifier, both before PUBLISH. Combined verdict gates PUBLISH. A failed PR forced up by a too-late audit is wasted CI minutes and a force-push.
14. **POST-HANDOFF-GUARD always runs** even when no handoff is declared. It verifies the merged state compiles end-to-end, catching stub-vs-real-impl drift the per-merge guards miss.
15. **Monotonic-progress over fixed caps.** Re-integration cycles continue while progress is strict (fewer failure_keys OR changed category). Stop only on stagnation (same failure_keys two consecutive attempts).
16. **Metric sanity is a hard gate.** Abort the loop at baseline if the verify command can't produce a meaningful number. Trusting a broken metric corrupts the entire keep/discard loop.
17. **Coordination Resilience: dual-channel reporting.** Verdict-bearing tasks (verify, audit, integrate, review) must instruct agents to post final results via BOTH TaskUpdate AND SendMessage. The Spec 02 retro saw ~7 tasks return "Task not found" mid-loop; SendMessage was the resilient fallback.

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
| mcp__claude-in-chrome__* | verifier | Interactive browser verification (preferred, native) |
| playwright-cli | verifier | Interactive browser verification (fallback) |
| Context7 MCP | all agents | Verify dependency APIs |

**Browser tool selection:** The verifier uses `mcp__claude-in-chrome__*` (native Claude browser
tools) when available, falls back to `playwright-cli` if Chrome MCP is not connected.
Automated E2E test suites (Playwright tests, Cypress, etc.) are always run directly.

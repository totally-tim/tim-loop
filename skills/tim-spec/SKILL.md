---
name: tim-spec
description: Use when starting a new feature - generates a structured spec through guided brainstorming that can be consumed by tim-loop
---

# Tim Spec — Feature Specification Generator

**Announce at start:** "I'm using the tim-spec skill to generate a feature specification."

## Overview

Generates a structured feature spec by wrapping the brainstorming skill with a standardized output format. The resulting spec is the input to `/tim-loop`.

Supports two input modes:
- **Default (brainstorming):** Guided brainstorming from scratch via `superpowers:brainstorming`
- **gstack import:** Detects and consumes existing gstack planning artifacts, then supplements with codebase exploration

## Process

### Step 0: Check for gstack Planning Artifacts

Before brainstorming, check for existing gstack planning output:

1. **Detect the project slug:** Derive from the current git repo name or working directory name.
2. **Scan for artifacts:** Look in `~/.gstack/projects/{slug}/` for:
   - Design docs: `*-design-*.md` (most recent by timestamp)
   - Test plans: `*-test-plan-*.md` (most recent by timestamp)
3. **If artifacts found:** Ask the user:
   > "I found gstack planning artifacts for this project:
   > - Design doc: `{filename}` ({date})
   > - Test plan: `{filename}` ({date})
   >
   > Would you like me to import these as the foundation for the spec, or start fresh with brainstorming?"

4. **If user chooses import:** Go to Step 1a (gstack import mode).
5. **If user declines or no artifacts found:** Go to Step 1b (brainstorming mode).

### Step 1a: gstack Import Mode

Read the gstack design doc and test plan. Extract and transform:

| gstack Source Section | → | Spec Target Section |
|---|---|---|
| Recommended Approach + Description | → | `## Goal` (distill to one sentence) |
| Implementation Sequence items | → | `## Requirements` — present to user for `[P0]`/`[P1]`/`[P2]` tagging |
| Success Criteria | → | `## Acceptance Criteria` (rewrite as testable conditions) |
| Test Plan: Key Interactions + Edge Cases | → | `## Test Strategy` (formalize with test types/frameworks) |
| Constraints + Premises + Risk annotations | → | `## Risk Assessment` |
| Open Questions | → | `## Open Questions` (carry forward) |
| Out of Scope / Scope boundaries | → | `## Out of Scope` |

**After extraction:**
- Present the extracted sections to the user for review and priority assignment.
- Ask clarifying questions for anything that didn't map cleanly.
- The user may adjust, add, or remove items.
- Then proceed to Step 2 (codebase exploration) — gstack provides design philosophy but not file-level architecture.

**Deriving Metric, Guards, and Verify Command from gstack:**
- If the test plan references specific test commands or coverage targets, use those to populate `## Metric` and `## Verify Command`.
- If the design doc mentions constraints or invariants, use those to populate `## Guards`.
- If these can't be derived, ask the user or leave as optional (tim-loop works without them, but is more effective with them).

### Step 1b: Brainstorming Mode (Default)

Invoke `superpowers:brainstorming` to explore the idea with the user. Follow the brainstorming process exactly (one question at a time, propose approaches, present design, get approval).

### Step 2: Explore the Codebase

After brainstorming approval (or gstack import review), explore the relevant parts of the codebase to populate the Architecture section with specifics: file paths, existing patterns, naming conventions, and relevant abstractions. Do not leave Architecture vague.

Additionally, discover information for the metric sections:
- **Metric:** Identify existing test commands, coverage tools, or measurable signals in the project.
- **Guards:** Identify the project's typecheck, lint, test, and build commands.
- **Verify Command:** Construct a mechanical command that extracts the metric value.

### Step 3: Generate Spec

Convert the brainstorming design (or gstack import) into the standardized spec format below. Every required section must be filled — if information is missing, ask the user before generating.

### Step 4: Validate Spec

Ensure these sections are present and non-empty:
- Goal (one sentence)
- Requirements (at least one, each with a priority tag `[P0]`/`[P1]`/`[P2]`)
- Acceptance Criteria (at least one testable criterion)

Recommended but not required:
- Metric (mechanical, fast, outputs a number)
- Guards (baseline invariants)
- Verify Command (extracts the metric)

### Step 5: Save Spec

Write to `docs/specs/YYYY-MM-DD-<feature-slug>.md` where `<feature-slug>` is a kebab-case name derived from the feature.

If gstack artifacts were imported, note the lineage in the spec header:
```markdown
<!-- Imported from gstack: {design-doc-filename}, {test-plan-filename} -->
```

### Step 6: Offer Next Step

"Spec saved to `<path>`. Run `/tim-loop <path>` to begin the automated build-verify-review loop."

## Spec Format

The spec MUST follow this exact structure:

```markdown
# Feature: <name>

## Goal
One sentence describing what we're building and why.

## Requirements
- [ ] [P0] Critical requirement — must ship
- [ ] [P0] Another critical requirement
- [ ] [P1] Important requirement — should ship
- [ ] [P2] Nice-to-have requirement — ship if time allows
- [ ] [P1] Non-functional: performance, security, etc.

## Architecture
How it fits into the existing codebase. Which domains/files are affected.
Reference CLAUDE.md and existing patterns.
Include specific file paths, naming conventions, and abstractions discovered
during codebase exploration. Do NOT leave this section vague.

When the feature spans multiple independent modules, clearly identify module
boundaries. This helps the architect agent partition work across parallel
builders. For example: "The API logic lives in src/api/, the business logic
in src/services/, and the UI in src/components/ — these are independent modules."

## Acceptance Criteria
Concrete, testable conditions that define "done".
- When X happens, Y should result
- The API should return Z status code with payload W

## Metric (recommended)
A mechanical, fast measurement that tracks progressive improvement.
When present, tim-loop uses metric-driven keep/discard iteration instead of
pure pass/fail verification. Without this, tim-loop falls back to pass/fail mode.

Command: `<shell command that outputs a single number>`
Direction: higher is better | lower is better
Baseline: <current value before implementation, discovered during codebase exploration>

Examples:
- Test count: `npm test 2>&1 | grep -c "✓"` (higher is better)
- Coverage: `npm test -- --coverage | grep "All files" | awk '{print $4}'` (higher is better)
- Type errors: `npx tsc --noEmit 2>&1 | grep -c "error TS"` (lower is better)
- Bundle size: `npx esbuild src/index.ts --bundle --minify | wc -c` (lower is better)

## Guards (recommended)
Baseline invariants that must NEVER break during implementation.
Guards are separate from feature verification — they protect existing functionality.
Each guard is a shell command that must exit 0.

- `<typecheck command>` — e.g., `npx tsc --noEmit`
- `<existing test command>` — e.g., `npm test -- --testPathIgnorePatterns="<new-test-patterns>"`
- `<lint command>` — e.g., `npm run lint`
- `<build command>` — e.g., `npm run build`

When a builder's change breaks a guard, that change is immediately reverted
(discarded) regardless of whether the feature metric improved.

## Verify Command (recommended)
The exact shell command to extract the metric value. Must output a single
parseable number. Used by the verifier to track progressive improvement.

`<command from ## Metric section above>`

## Test Strategy
What kinds of tests to write and how.
- Unit tests for: [specific modules/functions]
- Integration tests for: [specific flows]
- E2E tests for: [specific user journeys] (if applicable)
- Mocks/fixtures needed: [external services, test data]
- Test framework: [vitest/jest/pytest/etc. — match existing project]

## Risk Assessment
- Blast radius: [greenfield | modifies existing module | cross-cutting refactor]
- Risk level: [low | medium | high]
- Affected systems: [list of systems/modules touched]

## Open Questions (optional)
Unknowns the builder should investigate during codebase study.
- How does the existing auth middleware handle X?
- Is there a shared utility for Y?

## Loop Config (optional)
Override tim-loop defaults for this feature.
- max_outer_cycles: 3
- max_builder_iterations: 8
- require_plan_approval: true
- skip_baseline: false
- builder_count: auto
- max_builders: 5

## Verification (optional)
Custom verification steps beyond the default 3-tier verification.
- Run `specific-command` and expect X
- Check that Y is true in the browser at /path
- Skip Playwright (no frontend changes)

## Out of Scope
What this feature explicitly does NOT include.
Prevents scope creep during the automated loop.
```

## Priority Guidelines

When assigning priorities during brainstorming, use these criteria:

- **P0 (must ship):** Core functionality that defines the feature. Without these, the feature doesn't work. The loop will FAIL the review if P0 items are missing.
- **P1 (should ship):** Important supporting functionality. Error handling, edge cases, secondary flows. The reviewer flags missing P1s as NON-BLOCKING.
- **P2 (nice to have):** Polish, optimizations, secondary features. The reviewer notes missing P2s as OBSERVATIONS. Acceptable to skip if cycles run out.

If the user doesn't specify priorities, propose a priority assignment and get confirmation.

## Red Flags

- **Never skip brainstorming (or gstack import review).** Even if the user has a clear idea, the process surfaces edge cases and constraints. In gstack import mode, the user still reviews and adjusts.
- **Never generate a spec with empty Acceptance Criteria.** The verifier agent depends on these to check plan adherence.
- **Never leave Architecture vague.** Explore the codebase and populate with specific file paths and patterns.
- **Never save without user approval.** Show the full spec and get explicit "yes" before writing to disk.
- **Never omit priorities.** Every requirement must have a `[P0]`/`[P1]`/`[P2]` tag.
- **Never fabricate metric commands.** If you can't discover a mechanical metric during codebase exploration, leave the Metric/Guards/Verify Command sections empty rather than guessing. Ask the user if they know of one.
- **Never treat gstack import as a shortcut.** Imported artifacts still need codebase exploration (Step 2) and user review. gstack provides design intent; the spec needs implementation-level detail.

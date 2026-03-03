---
name: tim-spec
description: Use when starting a new feature - generates a structured spec through guided brainstorming that can be consumed by tim-loop
---

# Tim Spec — Feature Specification Generator

**Announce at start:** "I'm using the tim-spec skill to generate a feature specification."

## Overview

Generates a structured feature spec by wrapping the brainstorming skill with a standardized output format. The resulting spec is the input to `/tim-loop`.

## Process

1. **Invoke brainstorming:** Use `superpowers:brainstorming` to explore the idea with the user. Follow the brainstorming process exactly (one question at a time, propose approaches, present design, get approval).

2. **Explore the codebase:** After brainstorming approval, explore the relevant parts of the codebase to populate the Architecture section with specifics: file paths, existing patterns, naming conventions, and relevant abstractions. Do not leave Architecture vague.

3. **Generate spec:** Convert the brainstorming design into the standardized spec format below. Every required section must be filled — if information is missing from brainstorming, ask the user before generating.

4. **Validate spec:** Ensure these sections are present and non-empty:
   - Goal (one sentence)
   - Requirements (at least one, each with a priority tag `[P0]`/`[P1]`/`[P2]`)
   - Acceptance Criteria (at least one testable criterion)

5. **Save spec:** Write to `docs/specs/YYYY-MM-DD-<feature-slug>.md` where `<feature-slug>` is a kebab-case name derived from the feature.

6. **Offer next step:** "Spec saved to `<path>`. Run `/tim-loop <path>` to begin the automated build-verify-review loop."

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
- max_inner_retries: 5
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

- **Never skip brainstorming.** Even if the user has a clear idea, the brainstorming process surfaces edge cases and constraints.
- **Never generate a spec with empty Acceptance Criteria.** The verifier agent depends on these to check plan adherence.
- **Never leave Architecture vague.** Explore the codebase and populate with specific file paths and patterns.
- **Never save without user approval.** Show the full spec and get explicit "yes" before writing to disk.
- **Never omit priorities.** Every requirement must have a `[P0]`/`[P1]`/`[P2]` tag.

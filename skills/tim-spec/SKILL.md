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

2. **Generate spec:** After the user approves the brainstorming design, convert it into the standardized spec format below. Every section must be filled — if information is missing from brainstorming, ask the user before generating.

3. **Validate spec:** Ensure these sections are present and non-empty:
   - Goal (one sentence)
   - Requirements (at least one functional requirement)
   - Acceptance Criteria (at least one testable criterion)

4. **Save spec:** Write to `docs/specs/YYYY-MM-DD-<feature-slug>.md` where `<feature-slug>` is a kebab-case name derived from the feature.

5. **Offer next step:** "Spec saved to `<path>`. Run `/tim-loop <path>` to begin the automated build-verify-review loop."

## Spec Format

The spec MUST follow this exact structure:

```markdown
# Feature: <name>

## Goal
One sentence describing what we're building and why.

## Requirements
- [ ] Functional requirement 1
- [ ] Functional requirement 2
- [ ] Non-functional: performance, security, etc.

## Architecture
How it fits into the existing codebase. Which domains/files are affected.
Reference CLAUDE.md and existing patterns.

## Acceptance Criteria
Concrete, testable conditions that define "done".
- When X happens, Y should result
- The API should return Z status code with payload W

## Verification (optional)
Custom verification steps beyond the default 3-tier verification.
- Run `specific-command` and expect X
- Check that Y is true in the browser at /path
- Skip Playwright (no frontend changes)

## Out of Scope
What this feature explicitly does NOT include.
Prevents scope creep during the automated loop.
```

## Red Flags

- **Never skip brainstorming.** Even if the user has a clear idea, the brainstorming process surfaces edge cases and constraints.
- **Never generate a spec with empty Acceptance Criteria.** The verifier agent depends on these to check plan adherence.
- **Never save without user approval.** Show the full spec and get explicit "yes" before writing to disk.

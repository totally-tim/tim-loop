---
name: tim-spec
description: Use when starting a new feature - generates a structured spec through guided brainstorming that can be consumed by tim-loop
effort: max
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

### Step 1b-2: Scope Amplification

After brainstorming (or gstack import review) completes and before user journeys, push the user to think bigger:

1. **Ask the 10/10 question:**
   > "What would make this a 10/10 feature — not just functional, but polished and complete?
   > Think about what would make a user say 'this is really well done' vs 'this works.'"

2. **Propose 2-3 features beyond what the user asked for.** Look for:
   - Features that make the app feel complete (error states, loading states, empty states, zero-data states)
   - Features that add delight (animations, keyboard shortcuts, smart defaults, undo)
   - Features that prevent common frustrations (confirmation dialogs, autosave, input validation with helpful messages)
   - Features that round out the user experience (responsive design, accessibility, offline handling)

3. **Present as P1/P2 candidates.** The user decides what to include:
   > "Based on our discussion, here are a few additions that would elevate this feature:
   > - [P1 candidate] Error state handling with retry — when the API fails, show a clear message with a retry button instead of a blank screen
   > - [P2 candidate] Keyboard shortcut (Cmd+Enter) to submit the form — small polish that power users notice
   > - [P2 candidate] Optimistic UI update — show the result immediately while the API call completes in the background
   >
   > Want to include any of these?"

4. **Respect the user's scope decisions.** If they decline everything, proceed without adding scope. Never force features the user doesn't want.

### Step 1c: Co-create User Journeys with the User

**This step runs after brainstorming/import review, before codebase exploration.**

User journeys are the top-down integration tests that prevent the "green tests, broken app"
problem. They must be co-created with the user — not auto-generated — because only the user
knows the expected navigation paths and product behavior.

1. **Explain the purpose:**
   > "Now let's define how a user would actually reach and use this feature.
   > These journeys will be tested in a real browser during verification to catch
   > integration issues like missing pages, unhooked features, or partial implementations."

2. **For each acceptance criterion**, ask the user:
   - "Starting from where in the app, how would a user reach this?"
   - "What would they click/navigate through?"
   - "What should they see at each step?"
   - "What action triggers the acceptance criterion, and what's the expected result?"

3. **Draft each journey** as a sequence of steps with checkpoints:
   ```
   Journey: Create an invoice
   Start: http://localhost:3000 (app home)
   Steps:
     1. Navigate: Click "Dashboard" in sidebar
        Checkpoint: Dashboard page loads, "Invoices" section visible
     2. Navigate: Click "Invoices" → Click "Create Invoice" button
        Checkpoint: Invoice creation form renders with amount, recipient, due date fields
     3. Action: Fill amount=100, recipient=test@example.com, due date=tomorrow → Click "Submit"
        Checkpoint: Success toast appears, redirected to invoice list, new invoice visible
   ```

4. **Review with the user.** Present all journeys and get explicit confirmation:
   - "Do these journeys cover the critical paths?"
   - "Are there flows I'm missing?"
   - "Is the starting point correct for each?"

5. **For API-only features** (no UI): convert journeys to API call sequences:
   ```
   Journey: Rate limit enforcement
   Steps:
     1. Action: Send 100 POST requests to /api/invoices with valid auth
        Checkpoint: All return 200
     2. Action: Send 1 more POST request
        Checkpoint: Returns 429 with Retry-After header
   ```

6. **For gstack import mode:** also extract user journeys from the test plan's
   "Key Interactions to Verify" and "Critical Paths" sections, then present
   to the user for review and refinement.

### Step 2: Explore the Codebase

After user journey approval, explore the relevant parts of the codebase to populate
the Architecture section with specifics: file paths, existing patterns, naming
conventions, and relevant abstractions. Do not leave Architecture vague.

Additionally, discover information for the metric sections:
- **Metric:** Identify existing test commands, coverage tools, or measurable signals in the project.
- **Guards:** Identify the project's typecheck, lint, test, and build commands.
- **Verify Command:** Construct a mechanical command that extracts the metric value.

Also discover information relevant to user journeys:
- **App entry point:** What URL does the dev server serve? (e.g., `http://localhost:3000`)
- **Dev server command:** How to start it? (e.g., `npm run dev`)
- **Existing navigation:** What navigation patterns exist (sidebar, top nav, routing)?
- **Auth requirements:** Does the app require login? What test credentials exist?

### Step 2b: Identify Spike Tasks

If the spec involves **hardware APIs, undocumented system interfaces, or platform-specific
behavior**, you MUST identify spike tasks — small throwaway experiments that verify
assumptions before they propagate into the spec.

**When to add spike tasks:**
- The feature uses an undocumented or vendor-specific API (IOKit HID, private frameworks)
- The feature depends on specific hardware behavior (sensors, peripherals, GPU)
- The spec prescribes a specific implementation approach for something you haven't verified
- The feature uses a system API whose behavior varies by OS version or hardware model

**Process:**
1. Review the Architecture and Requirements for hardware/system API dependencies
2. For each dependency, ask: "Has this specific API surface been verified on the target platform?"
3. If not, create a spike task that can be run before the loop starts
4. Present spike tasks to the user: "These assumptions should be verified before building. Want to run them now?"

**If a spike can't be run** (no hardware access, no test environment):
- Do NOT prescribe the implementation approach in the spec
- Instead, mark it as "approach TBD — builder must research first"
- Add it to `## Open Questions` with the specific unknowns

### Step 2c: Identify Compiler Traps

For projects using **strict type systems or complex concurrency models** (Swift, Rust,
TypeScript strict mode, etc.), identify compiler traps that commonly cause builder
iterations to be wasted on type errors rather than feature work.

**When to add compiler traps:**
- Swift projects using `@MainActor`, `Sendable`, `@Observable`, SwiftData
- Rust projects with complex lifetime or borrow checker patterns
- TypeScript projects with strict mode, complex generics, or mapped types
- Any project where the compiler enforces patterns that are easy to get wrong

**Process:**
1. Read the project's compiler/build configuration
2. Identify strict settings that commonly trip up AI-generated code
3. Document the patterns as a `## Compiler Traps` section in the spec

These traps are injected into every builder's prompt by tim-loop so they avoid
burning iterations on type errors.

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
- User Journeys (end-to-end browser/API flows co-created with user)
- Spike Tasks (for hardware/undocumented API features — strongly recommended)
- Compiler Traps (for strict type systems — strongly recommended)

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

For **native apps** (macOS, iOS, Android), also include:
- `<build command>` — e.g., `xcodebuild -scheme MyApp build 2>&1 | tail -1` (must show BUILD SUCCEEDED)
- `<test command>` — e.g., `xcodebuild test -scheme MyApp -destination 'platform=macOS'`
- `<launch guard>` — verify the app launches without crashing:
  e.g., `open -W MyApp.app & sleep 3 && pgrep -x MyApp > /dev/null` (exits 0 if running)

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

## Spike Tasks (recommended for hardware/system API features)
Small throwaway experiments to verify assumptions BEFORE the loop starts.
Each spike is a shell command or small script that confirms an API works as expected.

- [ ] Spike: Enumerate HID devices and find the target sensor
  Command: `swift -e 'import IOKit.hid; ...'`
  Verifies: The sensor exists and is accessible with the expected UsagePage/Usage
- [ ] Spike: Read one raw value from the sensor
  Command: `swift -e '...'`
  Verifies: Data format (degrees vs centidegrees, byte order, etc.)

If a spike cannot be run (no hardware, no test environment), mark the corresponding
requirement's implementation approach as "TBD — builder must research first" and
add it to Open Questions.

## Compiler Traps (recommended for strict type systems)
Patterns that commonly cause AI-generated code to fail compilation. These are
injected into builder prompts to prevent wasted iterations on type errors.

Example (Swift with Concurrency):
- `@MainActor` is default isolation — `nonisolated` required on non-UI helpers
- `@Observable` requires `@Bindable var` for two-way bindings in views
- SwiftData `@Model` objects cannot cross actor boundaries — use value types
- `cos()` is ambiguous between `Double` and `CGFloat` — use explicit `CGFloat(cos(x))`
- NSOpenPanel requires `NSApp.activate()` in LSUIElement apps or it crashes

Example (Rust):
- Borrowed references in async blocks need `Arc`/`Clone`
- `Send + Sync` required for anything crossing thread boundaries

Example (TypeScript strict):
- `strictNullChecks` means optional chaining is mandatory
- Generic constraints must be explicit, not inferred

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

## User Journeys (recommended)
End-to-end flows that verify the feature works from a real user's perspective.
These are tested in a browser during integration completeness verification.
Co-created with the user during spec generation — never auto-generated.

App entry: http://localhost:<port>
Dev server: `<command to start dev server>`
Auth: <none | test credentials | login flow>

### Journey 1: <descriptive name>
- [ ] Step 1 — Navigate: <where to click/navigate>
  Checkpoint: <what should be visible/true>
- [ ] Step 2 — Navigate: <next navigation step>
  Checkpoint: <what should be visible/true>
- [ ] Step 3 — Action: <user action that triggers the feature>
  Checkpoint: <expected result — maps to an acceptance criterion>

### Journey 2: <descriptive name>
- [ ] Step 1 — Navigate: ...
  Checkpoint: ...
{Repeat for each critical path}

For API-only features, use API call sequences instead of browser navigation:
### Journey 1: <descriptive name>
- [ ] Step 1 — Request: POST /api/endpoint with {payload}
  Checkpoint: Response 200 with {expected body}

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
- **Never auto-generate user journeys.** User journeys must be co-created with the user. Only the user knows the expected navigation paths and product behavior. Present drafts for review, but never save without the user confirming the flows are correct.
- **Never skip user journeys for features with UI.** If the feature has any user-facing component, user journeys are critical for catching integration issues. For API-only features, use API call sequences instead.
- **Never prescribe implementation details for undocumented APIs.** If you haven't verified an API works a specific way (e.g., a HID sensor's data format, a private framework's behavior), don't write it into the spec as fact. Add a spike task instead, or mark the approach as "TBD — builder must research."
- **Never skip spike tasks for hardware features.** If the spec involves hardware sensors, peripherals, or platform-specific system APIs, spike tasks are critical. Wrong assumptions propagate through the architect's contract into every builder's work.

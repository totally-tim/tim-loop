# TODOS

## Harness Simplification Audit for Opus 4.6

**Priority:** Medium
**Added:** 2026-03-26
**Source:** Anthropic's harness design blog post — "every component in a harness encodes an assumption about what the model can't do on its own, and those assumptions are worth stress-testing."

**Context:** Tim-loop was designed around earlier Claude models. As models improve, some scaffolding may no longer be load-bearing. The article demonstrated this by removing the sprint construct when upgrading from Opus 4.5 to 4.6 — the model could handle coherent multi-hour sessions without decomposition. Tim-loop should undergo the same audit.

**Experiment Protocol:**

Run the same feature spec against different harness configurations. Compare output quality, iteration count, wall-clock time, and human intervention needed.

| Experiment | Config A (current) | Config B (simplified) | What to Compare |
|---|---|---|---|
| Partitioning | architect + N builders | single builder, no architect | Output quality, iteration count, file coherence |
| Keep/discard | commit-then-revert discipline | let model self-correct freely | Rollback frequency, dead ends, final code quality |
| Verification | 3-phase (guard + feature + integration) | Phase 1 only (guards) | Bug escape rate, stub count in final PR |
| Iron Laws | all 7-8 per agent | reduced to 3-4 critical ones | Agent adherence, context drift, prompt following |
| Contract negotiation | cycle 1 negotiation | skip negotiation entirely | Spec fidelity score, rework cycles |

**How to run:**
1. Pick a feature spec you've previously run through tim-loop successfully
2. Run it again with simplified config (override via `## Loop Config` in spec)
3. For each experiment, change only the variable being tested
4. Compare: PR diff quality, total iterations, wall-clock time, ABORT/NEEDS_HUMAN rate

**Blocked by:** Need a completed feature to use as baseline comparison.

**Expected outcome:** Identify which components are still load-bearing and which can be simplified or removed. Update the harness accordingly, documenting which assumptions were invalidated.

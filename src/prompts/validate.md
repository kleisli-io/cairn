---
description: Verify a cairn plan independently against phase acceptance and real outputs
argument-hint: "<plan task id, or empty to use current>"
---
# Validate

Validate skeptically. The implementation is not accepted until the plan graph,
recorded acceptance, code state, and verification output agree.

Plan id: $ARGUMENTS

## Orient

- If a plan id is provided, `task_bootstrap(task_id=<plan>)`.
- Run `task_query (query "plan")` for phase status and metadata.
- Run `task_query (query "plan-frontier")` to see unfinished ready work. Use
  `task_query (query "stale-phases")` or `task_query (query "orphans")` only
  when graph health is in question.
- If no plan is found, use `task_query (query "recent")` to find candidates and
  report that validation cannot proceed without a plan.

Done when the plan, phases, and expected acceptance gates are known.

## Verify

For each relevant phase:
- Read exact acceptance with `task_get(task_id=<phase>)`.
- Inspect changed files and compare the implementation to the phase objective.
- Run every verification command named by acceptance; capture pass/fail output.
- Use `timeline(task_id=<phase>, limit=...)` only when you need to reconstruct
  what was done, not as a substitute for verification.
- Use `task_search(query, task_id?)` only to cross-check specific prior findings
  from observations.

Done when every acceptance item is classified as pass, fail, or not verifiable
with evidence.

## Report

Report inline:
- phases checked;
- commands run and outputs;
- matches, deviations, and potential issues with `file:line` evidence;
- blocking failures versus non-blocking improvements;
- residual risk.

If a completed phase fails validation, say it should be reopened with
`task_update_status(status="active", reopen=true, task_id=<phase>)`; do not
silently mutate status unless the user asked validation to repair state.

## Gates (irreducible)
- Actually run named verification commands; do not accept self-reported success.
- Pre-existing tests must still pass.
- Do not declare success while blocking build/test failures remain.
- Every code-review finding has `file:line` evidence.

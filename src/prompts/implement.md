---
description: Advance a cairn plan one ready phase at a time behind real verification gates
argument-hint: "<existing plan task id, or empty to use current>"
---
# Implement

Advance the graph through gates by completing ready phases. A phase is ready when
`plan-frontier` says it is ready; a phase is complete only after its acceptance
actually passes.

Plan id: $ARGUMENTS

## Select task context

- If an existing plan task id is provided, `task_bootstrap(task_id=<plan>)` and
  use that plan.
- If no plan id is provided, inspect the current task with `task_bootstrap` and
  report the selected task id/name before continuing.
- If the current task is missing or ambiguous, use `task_query (query "recent")`
  or relevant task queries to show candidates and ask which plan to use.
- Do not create a new task from implement.

Done when exactly one plan task is selected and reported, or the user has been
asked to choose one.

## Orient

- Run `task_query (query "plan")` for the phase graph.
- Run `task_query (query "plan-frontier")` to choose ready phase(s).
- If a `plans/<topic>.md` artifact exists, read it as a map, then verify it
  against `task_query (query "plan")` and `task_query (query "plan-frontier")`.
  Trust the graph when they disagree and record the drift.

Done when exactly one ready phase is selected, or the plan is blocked/complete
and that state is reported.

## Work the phase

- Read phase scope with `task_get(task_id=<phase>)`; this avoids switching the
  current task away from the plan.
- Before editing, restate the phase objective, acceptance gate, and any evidence
  or constraints inherited from the plan.
- Implement with a red → green → refactor loop when tests are relevant.
- Record durable progress with `observe(task_id=<phase>, text=...)` at meaningful
  state changes: red, green, refactor, blocker, result.
- If the work deviates from the plan, record the deviation and update the DAG,
  plan artifact, or metadata instead of silently drifting.

Done when the phase acceptance has been implemented and the required checks have
been run.

## Advance the DAG

- Mark the phase complete only after its acceptance gate passes:
  `task_update_status(status="completed", task_id=<phase>)`.
- Mark it blocked when an external blocker prevents progress:
  `task_update_status(status="blocked", task_id=<phase>)`.
- Re-run `task_query (query "plan-frontier")` after status changes to see the
  next ready work.
- When no incomplete phases remain, set the parent metadata:
  `task_set_metadata(key="phase", value="complete", task_id=<plan>)`.

Done when completed/blocked status matches the verified result and the frontier
has been refreshed.

## Gates (irreducible)
- Do not mark a phase completed until its automated gate actually passes; show
  the passing output.
- Pre-existing tests must still pass.
- No TODO/FIXME/HACK in shipped code unless explicitly accepted.
- Require explicit human sign-off before destructive or irreversible actions.
- Do not create or switch tasks silently.

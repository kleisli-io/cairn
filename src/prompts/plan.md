---
description: Shape evidence into a verifiable cairn task DAG, or make a surgical DAG edit
argument-hint: "<goal, existing plan task id to iterate, or empty>"
---
# Plan

Shape evidence into a task DAG. The graph is the plan; `plans/<topic>.md` is a
reviewable map of the graph. Each phase must be independently verifiable.

Goal or plan id: $ARGUMENTS

## Select task context

- If an existing plan task id is provided, `task_bootstrap(task_id=<plan>)`, then
  inspect with `task_query (query "plan")` and `task_query (query "plan-frontier")`.
- If a goal is provided without a task id, inspect the current task with
  `task_bootstrap` and report the selected task id/name before continuing.
- If the current task is missing or ambiguous, use `task_query (query "recent")`
  or relevant task queries to show candidates and ask which task to use or
  whether to create a new parent plan task.
- Do not create a new parent task unless the user explicitly asks to create one.

Done when exactly one parent task is selected and reported, or the user has been
asked to choose or create one.

## Gather evidence

- Reuse research observations and relevant `research/<topic>.md` artifacts before
  re-deriving facts.
- If evidence is missing for a material phase decision, ask for more research or
  record the assumption explicitly in the plan artifact.
- Keep research descriptive: convert evidence into graph structure here, not in
  the research artifact.

Done when every major phase decision is backed by research, observation,
`file:line` evidence, or an explicit assumption.

## Build or edit the DAG

Use real graph edges, not naming conventions:
- Add a phase with `task_fork(name, from=<plan>, edge_type="phase-of",
  description=...)`. Always pass `from=` because `task_fork` makes the child
  current.
- Add ordering from dependent to prerequisite with
  `task_link(target_id=<prereq>, edge_type="depends-on", task_id=<dependent>)`.
  Encode real prerequisites only.
- Set phase scope and criteria with
  `task_set_metadata(key="objective"|"acceptance"|"tags", value=..., task_id=<phase>)`.
- Remove or reshape existing structure surgically with `task_sever`, `task_link`,
  and `task_set_metadata`; record the reason with `observe`.

Done when every phase has objective and acceptance metadata, and every dependency
edge represents a real prerequisite.

## Check readiness

Run `task_query (query "plan")` for the full phase graph and
`task_query (query "plan-frontier")` for phases ready to implement. If the
frontier surprises you, fix the edges rather than explaining around them.

Done when the frontier matches the intended prerequisite structure.

## Write the plan artifact

Create or update `plans/<topic>.md` in the task dir. The graph remains the source
of truth; the file is a reviewable map.

Include:
- plan task id;
- goal;
- evidence and research artifacts used;
- phase task ids with objective, acceptance, and dependencies;
- current frontier;
- risks, assumptions, and open questions.

Record the artifact path with `observe`, e.g. `Plan artifact: plans/<topic>.md`.

Done when the artifact names the same phase ids and frontier reported by
`task_query (query "plan")` and `task_query (query "plan-frontier")`.

## Gates (irreducible)
- Every phase is independently verifiable.
- Every phase has automated acceptance where possible and manual acceptance where
  judgment is required.
- No fake ordering by names like `p1` or `phase-1`; readiness comes from
  `depends-on` edges.
- Do not create or switch tasks silently.

---
description: Turn a goal into a phased plan as a cairn task DAG, or surgically iterate one
argument-hint: "<goal, plan task id to iterate, or empty>"
---
# Plan

A plan IS a task DAG, not a markdown file — the graph is the source of truth.
Each phase is independently verifiable and carries its own acceptance. See
cairn-method for phase-design principles. Reuse research observations as the
evidentiary base; don't re-derive them.

Goal or plan id: $ARGUMENTS

## Build the DAG (cairn affordances)
- Phases are CHILD tasks: task_fork(name, from=<plan>, edge_type="phase-of",
  description=…). ALWAYS pass from= — task_fork makes the child current
  unconditionally.
- Ordering = task_link(target_id=<prereq>, edge_type="depends-on") from the
  dependent phase to its prerequisite. Encode REAL prerequisites only — don't
  fake order by naming phases p1/p2.
- Per-phase scope/criteria: task_set_metadata(key="objective"|"acceptance"|"tags").
  Read any phase via task_get(task_id=…) without switching current.
- Use descriptive phase names (not p1/phase-1).

## Inspect plan state
- task_query (query "plan") — the current task's phases + status + deps
  (current-scoped: needs a current task; orient with task_bootstrap first).
- task_query (query "plan-frontier") — the READY phases (every depends-on
  predecessor completed); this is the readiness view. Build edges with the tools
  above — there is no scaffold tool.
- TQ: (-> (current) (:follow :phase-of) (:ids)) enumerates phases.

## Iterate an existing plan (be surgical, not a rewrite)
- add phase    → task_fork(... from=<plan>)
- remove phase → task_sever(target_id, edge_type="phase-of")
- reorder      → task_link / task_sever on depends-on edges
- rescope      → task_set_metadata + observe(the decision)
- task_bootstrap(plan_id) re-orients before editing.

## Gate
Every phase must carry automated + manual acceptance and be independently
verifiable. Encode real prerequisite ordering so plan-frontier is true.

Method, tool reference, and the cairn graph model: see the cairn-method skill.

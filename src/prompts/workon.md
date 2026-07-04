---
description: Reconcile a task or handoff with live cairn state before continuing work
argument-hint: "<task id, handoff path, or empty to list candidates>"
---
# Work on

Re-enter work by reconciling the requested task or handoff with live cairn
state. The live timeline, observations, and task graph are the source of truth;
handoff notes are maps that may be stale.

Argument: $ARGUMENTS

## Entry

- Handoff path (`*.md` or under `handoffs/`): read the note, derive the task id
  from its task directory, then `task_bootstrap(task_id=<id>)`.
- Task id: `task_bootstrap(task_id=<id>)`.
- Empty: use `task_query (query "recent")`, `task_query (query "active-roots")`,
  or `task_query (query "busy")` to find candidates; ask which one to resume.

Done when exactly one task is selected and bootstrapped, or no task can be
selected and the user has been shown concrete candidates.

## Reconcile

Start from `task_bootstrap`: it already gives computed task state, parent/
children/edges, metadata, recent observations, and latest handoff summaries.
Do not repeat it with `task_get` unless you need a fresh read after changing
state or need to inspect a different task without switching current.

Use narrower probes only when they answer a question bootstrap does not:
- Read the handoff note itself when a handoff path was provided; verify only the
  referenced paths and claims that affect the next action.
- Use `timeline(task_id?, limit=...)` to reconstruct event order or inspect
  exact handoff/create/update events; skip it when bootstrap is enough.
- If phased, use `task_query (query "plan")` for the phase graph and
  `task_query (query "plan-frontier")` for ready work. Use
  `task_query (query "stale-phases")` only when completed parents or active
  children look inconsistent.
- Use `task_search(query, task_id?)` only for older or specific observation
  findings; it searches observation text, not task names or graph state.

Done when the bootstrapped state plus any necessary probes either agree with the
handoff and key files, or every drift is named.

## Propose the next move

Report briefly:
- selected task and current status;
- relevant handoff, if any;
- confirmed state versus drift;
- the next 1–3 actions, with the first action explicit;
- whether the task is completed and needs an explicit reopen decision.

Do not start implementation until reconciliation is complete.

## Gates (irreducible)
- Verify referenced files and graph state before acting.
- When a handoff conflicts with timeline, observations, or task graph, trust the
  live stream and surface the conflict.
- If the task is completed, ask for or receive an explicit reopen decision before
  continuing: `task_update_status(status="active", reopen=true, task_id=...)`.

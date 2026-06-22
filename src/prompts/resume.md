---
description: Re-enter a task from live cairn state and any handoff, then propose next steps
argument-hint: "<task id, handoff path, or empty for injected context>"
---
# Resume

task_bootstrap is the canonical one-call re-entry — state, neighbors, open
handoffs, recent observations, and what parallel sessions touched, in one call.
Adopts current only if none set; emits no event, safe to call freely. Never
assume a handoff or recorded state still matches reality — verify, then propose.

Argument: $ARGUMENTS

## Entry (dispatch by argument shape, not steps)
- a path ending .md or under handoffs/ → handoff mode: read it (most recent by
  filename timestamp YYYY-MM-DD_HH-MM-SS); derive the task from its directory,
  then task_bootstrap(<id>).
- a task id → live mode: task_bootstrap("<id>").
- empty → use the injected session-start context. Its format is
  TASK[1]{dir,phase,last_artifact} — the first field before the comma is the task
  dir. With none, task_query (query "recent") lists recent tasks;
  (query "active-roots") / (query "busy") also locate live work.

## Orient & reconcile (cairn affordances)
- timeline(task_id?, limit?) — recent activity + handoff records (summary is the
  resumable field; optional path → a written note).
- A phased plan? task_query (query "plan") / (query "plan-frontier") show where to
  pick up; (query "stale-phases") flags drift.
- task_get / task_search confirm handoff-mentioned files and state still hold.
- Continue a completed task: task_update_status(status="active", reopen=true, task_id?).

## Gates (irreducible)
- Verify before acting: confirm referenced files + graph state still hold;
  reconcile drift first.
- The live timeline/observations are the source of truth; a handoff note
  SUPPLEMENTS — when they disagree, trust the live stream.
- If the task is completed, surface that and require an explicit reopen decision.

Method, tool reference, and the cairn graph model: see the cairn-method skill.

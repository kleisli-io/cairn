---
description: Handoff current task state so a later session can resume from live cairn truth plus a written note
argument-hint: "<next-session focus, or empty>"
---
# Handoff

Write a resumable handoff for the current task. The `handoff` tool's summary is
the load-bearing field; the markdown note is the richer map.

Next session focus: $ARGUMENTS

## Process

### Orient from the live stream
- Ensure a current task exists: use `task_bootstrap` or `task_create` if needed.
- Pull `task_get`, `timeline(limit=...)`, and relevant `task_search` results.
- If phased, run `task_query (query "plan")` and `task_query (query "plan-frontier")`.
- Check modified artifacts directly so file references are current.

Done when the current task, recent events, relevant observations, phase state,
and changed paths are all accounted for.

### Scaffold, then enrich
- Compose one concise summary stating where the work stands and the next move.
- Call `handoff(summary=<one line>)` before writing the note; it records the
  event and returns the path under `.kli/tasks/<task-id>/handoffs/`.
- Read the scaffolded file, then overwrite it with the structure below.

Done when the returned path has been read and rewritten.

### Structure

```markdown
---
created: <timestamp>
repository: <repo path or name>
git_branch: <branch>
git_commit: <commit>
task: <task id>
summary: <same one-line summary passed to handoff>
type: handoff
status: active
---

# Handoff: <task> — <brief description>

## Task State
- Current objective, status, and phase if any.
- Completed, active, blocked, and pending items from the task graph.

## Critical References
- The 2–3 must-read paths for the next session, with why each matters.

## Recent Changes
- What changed, with `file:line` or path references.

## Learnings
- Findings that matter later, each backed by `file:line`, URL, or observation.

## Artifacts
- Everything produced or updated.

## Action Items & Next Steps
1. The exact next action.
2. Verification or decision needed after that.

## Other Notes
- Constraints, risks, open questions, and anything deliberately not done.
```

Done when every section is populated or explicitly says `None known`, and every
claim that can be grounded has evidence.

## Gates (irreducible)
- Record the one-line summary with `handoff` before writing the markdown note.
- Read the scaffold before overwriting it.
- Treat timeline, observations, and task graph as source of truth; the note must
  not contradict them.
- Cross-reference existing `research/<topic>.md` or `plans/<topic>.md` artifacts when they matter.
- Prefer references over code blocks; use `file:line` when line numbers are stable.

## Present to User

After creating the document, respond:

```
Handoff created at: [path from tool]

To resume from this handoff in a new session:
  /workon [path from tool]
```

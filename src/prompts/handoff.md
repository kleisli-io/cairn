---
description: Compose and record a resumable handoff for the current task
argument-hint: "<optional guidance, or empty>"
---
# Handoff

A handoff lets another session resume cleanly. Be thorough yet concise: compact
the context without losing the load-bearing details. Prefer file:line references
over long code blocks.

Guidance: $ARGUMENTS

## Scaffold, then enrich (cairn affordances)
- First compose a concise one-line summary of where things stand — this is the
  field a resuming session reads first.
- handoff(summary=<one line>) — scaffolds the document, returns its path, and
  records the handoff event. Requires a current task; if none is set, run
  task_bootstrap or task_create first.
- Read the scaffolded file, THEN overwrite it with the rich handoff below (reading
  first avoids colliding with the scaffold).
- task_get / timeline(task_id?, limit?) / task_search(query) — pull the state,
  recent events, and related findings the handoff should capture.
- task_query (query "plan") / (query "plan-frontier") — if the task is phased,
  record the current phase and what remains.

## Structure
Frontmatter: date, git_branch, git_commit, repository, task, type: handoff,
status: active.

  # Handoff: <task> — <brief description>

  ## Task(s) — the work and the status of each item; if phased, call out the
  current phase.
  ## Critical References — the 2-3 must-read paths for the next session.
  ## Recent Changes — what changed, in file:line form.
  ## Learnings — what was discovered, each with file:line evidence.
  ## Artifacts — everything produced or updated, as paths or file:line references.
  ## Task Graph State — for a phased task: current, completed, and pending phases
  plus related tasks, from task_query (query "plan").
  ## Action Items & Next Steps — a numbered list of what to do next.
  ## Other Notes — anything else worth carrying over.

## Gates (irreducible)
- Record the one-line summary via the handoff tool BEFORE writing the file.
- Read the scaffold before overwriting it.
- Cross-reference research.md and plan.md when they exist.
- The live timeline and observations are the source of truth; the handoff
  supplements them — never contradicts.

Method, tool reference, and the cairn graph model: see the cairn-method skill.

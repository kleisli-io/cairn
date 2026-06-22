---
description: Document the codebase as-is through grounded research with observation capture
argument-hint: "<research question, or empty to be prompted>"
---
# Research

Document what IS, not what should be — findings are descriptive observations,
not prescriptions. Reusable patterns come later, not here. See cairn-method for
the documentarian discipline.

Question: $ARGUMENTS

## Investigate
Single-agent: investigate directly with your own Read/Glob/Grep/Web tools —
cairn has no delegation surface. Prefer verified file:line / source-URL evidence
over inference; research errors propagate into every downstream phase.

## Record (cairn affordances)
- Establish a current task FIRST — task_create(name) adopts-as-current only if
  none set, or task_set_metadata(key="phase", value="research"). observe and the
  knowledge query are current-scoped and error with no current task.
- observe(text, task_id?) — the sink for every finding; the cheap heartbeat.
  Vocabulary: "Research finding: …", "Architecture insight: …", "Constraint found: …".
- task_search(query) — full-text over PRIOR observations; check what is already
  documented before re-investigating.
- task_query (query "knowledge") — accumulated knowledge from the current task.
- task_bootstrap(task_id) re-orients mid-stream; handoff(summary, path?) if the
  work spans sessions.

## Gate
Every claim carries file:line or a source URL. State hypotheses AS hypotheses
(tentative language) until verified. Describe, don't prescribe.

Method, tool reference, and the cairn graph model: see the cairn-method skill.

---
description: Gather evidence for a research question in observations, not prescriptions
argument-hint: "<research question, existing task id, or empty>"
---
# Research

Gather evidence about what exists. Findings are descriptive observations, not
recommendations; plans and reusable patterns come later.

Question or task id: $ARGUMENTS

## Select task context

- If an existing task id is provided, `task_bootstrap(task_id=<id>)` and use that
  task.
- If no task id is provided, inspect the current task with `task_bootstrap` and
  report the selected task id/name before continuing.
- If the current task is missing or ambiguous, use `task_query (query "recent")`
  or relevant task queries to show candidates and ask which task to use.
- Do not create a new task unless the user explicitly asks to create one.

Done when exactly one task is selected and reported, or the user has been asked
to choose or create one.

## Orient

- If the research question is empty or unclear, ask for it before digging.
- Search prior observations with `task_search(query, task_id?)` before repeating
  investigation. Use `task_query (query "knowledge")` when you need the current
  task's related knowledge graph.
- Reuse existing `research/<topic>.md` artifacts when they answer part of the
  question.

Done when the scope is clear and relevant prior evidence has either been reused
or ruled out.

## Investigate

Use direct code/source inspection. Prefer file paths, line numbers, and source
URLs over inference. Mark unverified ideas as hypotheses until checked.

Record each durable finding with `observe(text=..., task_id=<task>)`. Useful
prefixes: `Research finding:`, `Architecture insight:`, `Constraint found:`.

Done when every answer to the question is backed by evidence, and every open
uncertainty is named as a hypothesis or gap.

## Report

Create a `research/<topic>.md` artifact in the task dir.

Summarize:
- answer to the research question;
- key evidence as `file:line` or URL;
- constraints discovered;
- planning inputs: systems/files likely affected and verification surfaces found;
- open questions or gaps.

Record the artifact path with `observe`, e.g. `Research artifact: research/<topic>.md`.

## Gates (irreducible)
- Every factual claim has `file:line`, URL, or an observation reference.
- Do not prescribe implementation work in research findings.
- Do not create or switch tasks silently.

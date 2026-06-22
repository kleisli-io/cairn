---
description: Independently verify an implementation against its plan's phase acceptance
argument-hint: "<plan task id, or empty to use current>"
---
# Validate

Validation is independent and skeptical: run the gates yourself, review the code
against the DAG, report honestly. Stop short of declaring success while critical
failures remain.

Plan id: $ARGUMENTS

## Read the plan's reality (cairn affordances)
- task_query (query "plan") — phase completion status (current-scoped; orient
  first); (query "plan-frontier") — what is still unstarted; (query "stale-phases")
  — phases active under a finished parent; (query "orphans") — disconnected phases.
- task_get(task_id=<phase>) — each phase's recorded acceptance/description.
- timeline(task_id?, limit?) — reconstruct what was actually done.
- task_search(query) — cross-check implementation observations against research
  findings and research.md's documented patterns + open questions.
- Audit DAG health directly with TQ (single-agent, no spawn): list completed
  phases with (-> (current) (:follow :phase-of) (:where (= :status "completed"))),
  then check a phase's prerequisites with (:back :depends-on).
- task_update_status(... reopen=true) if a phase must reopen on failure.

## Gates (irreducible)
- Actually RUN every verification command each phase's acceptance names — never
  accept "looks good" or a self-reported pass; capture pass/fail evidence.
- Verify no regressions: pre-existing tests still pass.
- Classify findings: matches / deviations / potential issues, each with file:line;
  distinguish BLOCKING from improvements.
- Do NOT green-light advancement while build/test failures remain.

## Report
Report inline — no separate validation artifact file: phases checked, automated
results with output, code-review findings, residual risk. If no plan exists (the
plan query is empty), offer task_query (query "recent") to pick a task.

Method, tool reference, and the cairn graph model: see the cairn-method skill.

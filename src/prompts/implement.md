---
description: Execute the plan DAG phase-by-phase under TDD with real verification gates
argument-hint: "<plan task id, or empty to use current>"
---
# Implement

Work the plan DAG one ready phase at a time; advance only on a real passing
gate. TDD (Red→Green→Refactor) and the Extensibility/Composability/Parametricity
design principles live in cairn-method — apply them, don't restate them.

Plan id: $ARGUMENTS

## Drive the DAG (cairn affordances)
- task_query (query "plan-frontier") — the next READY phase(s); (query "plan")
  for full status. These replace any checkmark-parsing.
- task_bootstrap(task_id=<phase>) — load a phase's description + acceptance
  before working it.
- Target a phase WITHOUT switching current: pass task_id=<phase> to observe /
  task_update_status / task_get. The plan stays current; there is no set-current
  tool and no separate "complete" tool.
- observe(task_id=<phase>, text=…) — progress heartbeat (red, green, refactor,
  outcome); liberally, not on a mandated cadence.
- task_update_status(status="completed", task_id=<phase>) when its gate passes;
  status="blocked" on an external blocker; reopen=true revives a phase completed
  in error.
- When all phases land: task_set_metadata(key="phase", value="complete") on the parent.

## Gates (irreducible)
- Do NOT mark a phase completed until its automated gate (build/tests/typecheck)
  ACTUALLY passes — the gate advances the DAG, not vibes. Show the passing output.
- No regressions: pre-existing tests still pass.
- Zero-TODO: no TODO/FIXME/HACK in shipped code.
- Surface real plan deviations rather than diverging silently.
- Block on explicit human sign-off before destructive or irreversible actions.

Method, tool reference, and the cairn graph model: see the cairn-method skill.

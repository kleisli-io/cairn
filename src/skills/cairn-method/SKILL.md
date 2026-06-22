---
name: cairn-method
description: Reference and disciplines for working in the cairn task graph — its 14 tools, the task_query (TQ) grammar, named and user-defined views, the phase-of/depends-on/related edge model, and the documentarian, TDD, and Extensibility/Composability/Parametricity stances. Use when researching, planning, implementing, or validating work tracked in cairn, or when composing task_query, task_query_write, task_fork, task_link, or task_update_status calls.
---

# cairn-method

Domain knowledge for working in cairn — a task graph plus observation memory.
Reach here for cairn's tool surface (what each tool does, its arguments, and the
current-task rules), the task_query (TQ) grammar and named queries, the graph and
edge model, and the engineering disciplines — documentarian research, TDD, and the
design principles — that research, planning, implementation, and validation rely on.

## What cairn is

A task-graph plus observation memory. Tasks are nodes addressed by a **slug** —
date-prefixed and slugified, e.g. `2026-06-20-ship-the-thing`. Every write appends
one event to a durable log and folds into a queryable projection. State is
**per-session**: each session carries its own *current task* pointer; most tools
act on the current task unless you pass an explicit `task_id`.

## The 14 tools

cairn exposes exactly fourteen tools to the model.

**Record (cheap, frequent)**

| Tool | Args | Semantics |
|---|---|---|
| `observe` | `text`, `task_id?` | Record a freeform observation on the current (or named) task. The cheapest call — the work heartbeat. |
| `handoff` | `summary`, `path?`, `task_id?` | Scaffold a resumable handoff. `summary` is load-bearing. When `path` is omitted, cairn writes a timestamped skeleton note under the task scratchpad and returns its path for you to overwrite with a rich body. |

**Lifecycle**

| Tool | Args | Semantics |
|---|---|---|
| `task_create` | `name`, `description?` | Create a top-level task. Adopts as current only when no current task is set. |
| `task_fork` | `name`, `from?`, `edge_type?`, `description?` | Create a child task (default edge `phase-of`) and make the child current — unconditionally. Parent defaults to current when `from` omitted; always pass `from=<parent>`. |
| `task_update_status` | `status`, `task_id?`, `reopen?` | `status` ∈ open\|active\|completed\|abandoned\|blocked. `reopen=true` with no `status` revives to `active`. |
| `task_set_metadata` | `key`, `value`, `task_id?` | One free key/value (`display-name`, `phase`, `objective`, `acceptance`, `tags`). Upsert per key. |

**Edges**

| Tool | Args | Semantics |
|---|---|---|
| `task_link` | `target_id`, `edge_type`, `task_id?` | Typed edge from the current (or named) task to `target_id`. `edge_type` is required, no default: `phase-of`\|`depends-on`\|`related`. |
| `task_sever` | `target_id`, `edge_type`, `task_id?` | Remove that typed edge. `edge_type` required. |

**Read**

| Tool | Args | Semantics |
|---|---|---|
| `task_get` | `task_id?` | Computed state for one task: status, description, parent, children, outgoing edges, metadata, the 5 most-recent observations. |
| `timeline` | `task_id?`, `limit?` | Recent raw events for one task, newest first (`limit` default 20, cap 200). |
| `task_search` | `query`, `limit?`, `task_id?` | Full-text ranked search over observation text; returns matching tasks + a snippet. |

**Query / Orient**

| Tool | Args | Semantics |
|---|---|---|
| `task_query` | `query` | Read-only composable graph query (TQ grammar below). `!`-forms (mutating steps, define!) are rejected; set-ops and views resolve. |
| `task_query_write` | `query` | The write surface for the same language: mutating steps (`(:set-status! …)`, `(:set! …)`, `(:link! …)`, `(:unlink! …)`) and view definitions (`(define! "name" Q)` / `(undefine! "name")`). Read-only queries run here too, but prefer `task_query`. |
| `task_bootstrap` | `task_id?` | One-call orient: state, neighbors, open handoffs, recent observations, a 60-minute swarm readout. Adopts as current only when none set. Emits no event. |

That is fourteen: Record 2, Lifecycle 4, Edges 2, Read 3, Query/Orient 3.

## Current-task & task_id rules — the part a model cannot infer

- **No set-current tool is exposed.** Three tools *adopt* current, and only when
  none is set: `task_create`, `task_bootstrap`, and `task_fork`'s parent-defaulting.
- **`task_fork` ALWAYS makes the new child current — unconditionally**, even when a
  current task already exists. It is the one tool that overrides the pointer.
  Because the parent also defaults to current, **always pass `from=<parent>`.**
- **To act on any task without disturbing current, pass `task_id=<slug>`.** Nearly
  every tool takes an optional `task_id`.
- **`task_link` / `task_sever` treat `task_id` as the edge SOURCE and `target_id`
  as the DESTINATION.** `edge_type` is required, with no default.
- **Re-orient freely with `task_bootstrap(task_id=…)`** — it never overrides current
  and emits no event.
- A tool resolving to "the current task" with none set returns an error asking you
  to pass `task_id` or select one first. Establish a current task before any
  current-scoped query (see Named queries).

## TQ grammar

A query is a source form, optionally threaded through steps with `->`. Every
form is a parenthesized form — no bare keywords.

- **Sources:** `(all)` · `(node "substr")` (slug substring) · `(active)`
  (open/active/blocked) · `(dormant)` (completed/abandoned) · `(current)` (errors
  if none) · `(query "name")` · the reflective sources `(schema)` `(views)`
  `(fields)` `(edges)` (see Reflection).
- **Transformer steps** (node-set → node-set, compose freely): `(:follow EDGE)`
  `(:back EDGE)` `(:where PRED)` `(:sort FIELD)` `(:take N)` `(:enrich)`. `:sort`
  is descending; `:enrich` adds obs-count / edge-count / promoted metadata.
- **Set algebra** (combine the pipeline with a sub-query `Q` by task identity):
  `(:union Q)` `(:intersect Q)` `(:minus Q)`. `Q` is any query, evaluated
  read-only; e.g. `(-> (active) (:minus (-> (current) (:follow :phase-of))))`.
- **Coalesce & closure:** `(:or-else Q)` — the pipeline if it holds any task, else
  the read-only sub-query `Q` (a fallback). `(:closure EDGE…)` — the forward
  transitive closure over the `EDGE`s, cycle-safe and depth-bounded; the seeds are
  excluded unless a cycle returns to them.
- **Shaper steps** (terminate into a value): `(:select FIELD…)` `(:group-by FIELD)`
  `(:ids)` → slugs · `(:count)` → an integer.
- **Edges:** `phase-of` and `forked-from` (both parent/child via the structural
  fibration; the store does not distinguish them) · `depends-on` · `related`. An
  unknown edge type is an error, never a silent empty result.
- **Predicates:** `(= LHS v)` · `(has :field)` · `(matches :field "substr")`
  (`:slug` matches the slug) · `(> LHS n)` `(< LHS n)` `(>= LHS n)` ·
  `(and …)` `(or …)` `(not …)`. `LHS` is a field or `(count TRAV)` (its
  cardinality). Numeric comparisons require a numeric field (`:obs-count`,
  `:edge-count`, `:*-ts`) or a count; on a text field they error rather than
  silently fail.
- **Quantifiers** test a predicate over the tasks one hop from the row being
  filtered: `(all TRAV PRED)` `(any TRAV PRED)` `(none TRAV PRED)`, where `TRAV`
  is `(:follow EDGE)` or `(:back EDGE)`. The empty traversal makes `all`/`none`
  vacuously true and `any` false; an unknown edge errors even over an empty set.
  E.g. a ready phase is `(and (not (or (= :status "completed") (= :status
  "abandoned"))) (all (:follow :depends-on) (or (= :status "completed") (= :status
  "abandoned"))))` — exactly what `plan-frontier` now is.
- **Worked example:** `(-> (current) (:follow :phase-of) (:ids))` → the slugs of
  the current task's child phases.
- **One concrete invocation shape:** call `task_query` with `query` set to
  `(query "plan-frontier")`.

## Reflection — the language describes itself

Four sources answer the grammar *as a query*, each generated from the same
registries the interpreter dispatches on, so the description can never drift from
behavior. They return node-sets like any source, so the same steps compose over
them — don't read a fixed list, probe and filter:

- `(schema)` — every source, step, and write form, tagged `:category`
  (`source`/`step`/`write`) and steps by `:kind` (`transformer`/`shaper`), each
  with its `:doc`. E.g. `(-> (schema) (:where (= :kind "shaper")) (:ids))` lists
  the terminal steps.
- `(views)` — the named views, each tagged `:origin` (`builtin`/`user`) with its
  `:source` text. `(-> (views) (:where (= :origin "user")))` is what you defined.
- `(fields)` — the queryable fields, each with its `:type` (`text`/`number`).
- `(edges)` — the edge vocabulary, each with its `:class`
  (`structural`/`lateral`).

The tool descriptions stay minimal on purpose: they name only the fixed shape and
point here, so a smarter model probes the grammar instead of being handed a list
that rots.

## Named queries — 10 built-in views, 11 accepted names

| Name | Returns |
|---|---|
| `active-roots` | top-level tasks (no parent) that are open/active/blocked |
| `orphans` | top-level tasks with no parent, no children, no edges |
| `leaf-tasks` | active tasks with no children |
| `stale-phases` | active tasks whose parent is already completed/abandoned |
| `plan` | the current task's child phases — or its SIBLING phases when current is itself a leaf. Current-scoped; requires a current task; NOT a global phase list. |
| `plan-frontier` | the `plan` phases that are ready: not done, every `depends-on` predecessor completed. `frontier` is an accepted alias. |
| `recent` | up to 20 active tasks, most recently updated |
| `busy` | up to 20 active tasks ranked by observation count |
| `hub-tasks` | up to 20 active tasks ranked by edge count |
| `knowledge` | the current task plus its forward closure over children + lateral edges (depth-bounded), enriched. Current-scoped — errors with no current task. |

Each built-in is itself a TQ expression resolved by the same interpreter, so the
language hosts its own vocabulary.

## Defining views — `task_query_write`

Views are data, not hardcoded surface. On the **write** tool `task_query_write`:

- `(define! "name" Q)` validates `Q` (which must be node-set-valued, so it composes
  as a source), stores its text, and returns `Q`'s tasks. `(query "name")` then
  resolves it — including under the read-only `task_query`. A user view **shadows**
  a built-in of the same name; `(undefine! "name")` removes the user view and the
  built-in reappears.
- Definitions are recorded as events under a reserved namespace node, so they
  **survive a rebuild** and replay like any other fact. The namespace node never
  shows up in `(all)`/`(active)`/`(dormant)`.
- `define!`/`undefine!` are `!`-forms: **refused on `task_query`** (read-only),
  accepted on `task_query_write` (`:cairn/write`). The capability gate, not the
  grammar, is the read/write boundary.

## Mutating steps — writing through the language

A mutation is a **step**, so a write is just a pipeline. Each is a transformer
(node-set → node-set) that records a per-task event and returns the set, so it
composes — append `(:count)` to learn how many tasks it touched. All are `!`-forms,
accepted only on `task_query_write`.

- `(:set-status! STATUS)` — set each task's status (the enum: `open`/`active`/
  `completed`/`abandoned`/`blocked`). E.g. close the ready frontier in one line:
  `(-> (query "plan-frontier") (:set-status! "completed"))`.
- `(:set! :key "value")` — set a metadata field on each task (not `:slug`/`:status`).
- `(:link! :edge "target")` / `(:unlink! :edge "target")` — add/remove a lateral
  edge (`depends-on`/`related`/`phase-of`) from each task to a constant target.

Guarantees: effects **converge on re-run** (status, metadata, and edges settle to
the written value), each event is its own transaction (**partial-progress-safe**),
and only real tasks are touched — a synthesized reflection node is passed over.
**Operands stay read-only**: a `!`-step inside a `(:union …)`/`(:where …)` sub-query
is refused even on the write surface — you combine and filter selections, you do
not mutate inside them.

## Edge model & plan-as-DAG

- **`phase-of` is structural:** the parent/child relation folded into a single
  parent pointer. `:follow :phase-of` → children; `:back :phase-of` → parent. At
  most one parent per task.
- **`depends-on` / `related` are lateral** directed edges; `depends-on` encodes
  ordering / prerequisite.
- **`forked-from` exists internally as a structural alias of the parent pointer but
  is NOT a model-facing `edge_type` you pass** — the only values you pass are
  `phase-of`, `depends-on`, `related`.
- **A plan is a task DAG:** phases are `task_fork` children (`phase-of`); ordering
  is `task_link … depends-on`; `plan` lists the phases, `plan-frontier` the ready set.

## Documentarian stance

Document what **IS** — where it lives, how it works, how components interact — not
what should be. Unless explicitly asked, NEVER: suggest improvements, root-cause
prescriptively, propose refactors, or critique quality. ALWAYS: back every claim
with `file:line`; include snippets where they help; list the files you examined.
When investigating a bug, state hypotheses **as** hypotheses, in tentative language
("appears to", "may be", "evidence points to"), and keep the work `incomplete`
until a root cause is reproduced → fixed → confirmed → free of regressions.

## Phase-design judgment

Each phase is one logical unit with clear boundaries (each file or function belongs
to exactly one phase), builds on the previous via a real `depends-on` chain (never
faked by naming), and is **independently verifiable, carrying its own acceptance**.
Every phase carries BOTH automated verification (build, tests, lint/typecheck,
zero-TODO) AND manual verification (acceptance, regressions, UX) — both blocking.
Name what the plan is **not** doing (out-of-scope, with rationale). Mid-flight scope
reduction is legitimate prioritization when earlier phases already deliver value.
Aim for the right granularity: coarse enough to verify, fine enough to bound.

## TDD discipline (non-negotiable)

- **Red** — write the failing test FIRST, failing for the RIGHT reason ("not
  implemented" / "not defined", not a syntax, import, or test-logic error). If it
  fails for the wrong reason, fix the test.
- **Green** — write the minimum code to pass; run tests frequently.
- **Refactor** — improve while green, applying the design principles below, ONE
  change at a time, re-running after each.

Loop one feature at a time: test → implement → refactor → verify. Avoid
implementing before testing, skipping Red, skipping Refactor, and batching
features. For integration, test the real interaction rather than mocks, and add
tracing when debugging it.

## Design principles, with code

The refactor compass. Apply these in the Refactor step and whenever shaping an
interface.

**Extensibility** — *Can new variants be added without modifying existing code?*
Prefer directory-based registration and plugin discovery; avoid hardcoded lists,
enums, and switches. Refactor question: *"How would I add a new variant without
modifying this code?"*

```python
plugins/
  http.py        # HTTP plugin
  file.py        # File plugin
  network.py     # Network plugin (added later without modifying existing code)

def load_plugins(directory):
    return [import_module(f) for f in glob(f"{directory}/*.py")]

# Bad: hardcoded list (requires modification to extend)
def available_backends():
    return ["http", "file", "network"]   # edit this when adding a backend

# Good: discovery-based (no modification needed)
def available_backends():
    return [b.name for b in load_backends("src/backends/")]
```

**Composability** — *Can components be combined in new ways?* Prefer middleware /
pipeline patterns, pure data structures, and function composition. Refactor
question: *"Can I combine this with other components in new ways?"*

```python
# Handlers compose naturally (middleware / pipeline)
app = Pipeline(authenticate, authorize, handle_request)

# Good: pure function, composes easily
def process_data(data, config):
    return transform(data, config.transform_fn)

# Function composition: small, focused functions that combine
def process_pipeline(input):
    return persist(transform(validate(input)))
```

**Parametricity** — *Are values parameterized instead of hardcoded?* Take config
through arguments or environment; avoid magic strings/numbers and deployment
assumptions (paths, ports, URLs). Refactor question: *"Are there hardcoded values
that should be parameters?"*

```python
# Bad: magic number
def retry_operation(op):
    for _ in range(3):          # why 3?
        attempt(op)

# Good: parameterized
def retry_operation(op, max_retries=3):
    for _ in range(max_retries):
        attempt(op)

# Bad: assumes environment
def connect_db():
    return connect("localhost", 5432)

# Good: configurable
def connect_db(host, port):
    return connect(host, port)

# Bad: assumes a path
def load_config():
    return read_file("/etc/myapp/config.toml")

# Good: path provided by the caller
def load_config(config_path):
    return read_file(config_path)
```

## Zero-TODO, deviations & artifacts

- **Zero-TODO:** no `TODO` / `FIXME` / `HACK` in committed code. Enforce it over the
  diff (`git diff --name-only | xargs rg "TODO|FIXME|HACK"` returns nothing). Either
  complete it, file an issue and remove it, or move it to out-of-scope and remove it.
- **Deviation handling:** when reality differs from the plan, pause and surface
  plan-expected vs reality-found with a proposed adaptation and options (proceed
  adapted / update the plan / take a different approach); get the decision; record
  it with `observe`.
- **Artifact contracts** (the graph is authoritative; these are optional human
  summaries). `research.md`: `# Research: <topic>` / Summary (2-3 sentences) /
  Detailed Findings (per component, with `file:line`) / Open Questions / References
  / status `complete|incomplete`. `plan.md`: Overview / Current State / per-phase
  (Changes Required, Success Criteria split automated/manual, exit criteria) / What
  We're NOT Doing / references back to `research.md` with `file:line`.

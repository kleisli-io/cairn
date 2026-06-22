# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-06-22

The first release of cairn, a SQLite-backed task graph and observation store
packaged as a kli extension.

### Added

- **Task graph** with slug-addressed tasks (date-prefixed, slugified) and a typed
  edge model: structural `phase-of` (single parent) plus lateral `depends-on` and
  `related`. A plan is expressed as a task DAG.
- **Observation memory** — freeform notes appended to tasks, recorded as
  append-only events.
- **Durable event log + projection.** Every write appends one event and folds into
  a queryable projection; effects converge on rebuild, so state and user-defined
  views survive a replay.
- **14-tool surface**, capability-gated (read / write / observe):
  - Record: `observe`, `handoff`
  - Lifecycle: `task_create`, `task_fork`, `task_update_status`,
    `task_set_metadata`
  - Edges: `task_link`, `task_sever`
  - Read: `task_get`, `timeline`, `task_search`
  - Query / Orient: `task_query`, `task_query_write`, `task_bootstrap`
- **task_query (TQ) language** — composable graph queries: sources threaded
  through transformer and shaper steps with `->`, set algebra (`:union`,
  `:intersect`, `:minus`), coalescing (`:or-else`) and transitive `:closure`,
  predicates and quantifiers. The grammar is self-describing through the `(schema)`,
  `(views)`, `(fields)`, and `(edges)` reflective sources.
- **10 built-in named views** (11 accepted names): `active-roots`, `orphans`,
  `leaf-tasks`, `stale-phases`, `plan`, `plan-frontier` (alias `frontier`),
  `recent`, `busy`, `hub-tasks`, `knowledge`.
- **User-defined views** via `task_query_write`: `(define! "name" Q)` /
  `(undefine! "name")`, persisted as events and resolvable through `(query
  "name")`. User views shadow built-ins of the same name.
- **Mutating query steps** on the write surface — `(:set-status! …)`,
  `(:set! …)`, `(:link! …)`, `(:unlink! …)` — each recording a per-task event,
  converging on re-run, and partial-progress-safe. Sub-query operands stay
  read-only.
- **Per-session current-task model.** Each session carries its own current-task
  pointer; `task_create`, `task_fork`, and `task_bootstrap` adopt current only
  when none is set, while `task_fork` always makes the new child current.
- **Full-text search** over observation text via SQLite FTS5, ranked with
  snippets (`task_search`).
- **FTS5 build gate** — the build fails when the linked SQLite lacks FTS5.
- **Bundled resources** — workflow prompts (`research`, `plan`, `implement`,
  `validate`, `resume`, `handoff`) and the `cairn-method` skill, mounted by the
  host kli runtime.
- **Nix flake** exposing the library (`packages.cairn`), the FiveAM test suite and
  FTS5 drift gate (`checks`), and an SBCL + SQLite dev shell, for
  `x86_64-linux`, `aarch64-linux`, and `aarch64-darwin`.

[0.1.0]: https://github.com/kleisli-io/cairn/releases/tag/v0.1.0

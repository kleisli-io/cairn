# Changelog

All notable changes to cairn are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-07-04

First public release of cairn — a durable task graph your agent plans in and resumes into. When a session resets, the agent reloads the plan from the graph instead of reconstructing it from the conversation: open phases, dependencies, status, and the reasoning behind each decision are all still there. cairn ships as a [kli](https://github.com/kleisli-io/kli) extension and serves to any MCP client — Claude Code, Claude Desktop, Cursor — with a single `kli mcp-serve cairn`.

### Added

- **Plan as a task graph.** Slug-addressed, date-prefixed tasks and a typed edge model — structural `phase-of` (single parent) plus lateral `depends-on` and `related` — so a plan is a queryable DAG, not a paragraph buried in the transcript.
- **One-call re-entry.** `task_bootstrap` drops the agent back exactly where it left off — state, neighbors, open handoffs, recent observations, and what other sessions are doing — in a single call.
- **Observation memory.** Freeform notes attach to tasks as the work happens, so the reasoning behind a decision is still around when you need it; they're the cheapest write, made to be recorded as you go.
- **Full-text recall.** Observations are indexed with SQLite FTS5 and ranked with snippets, so finding "what we worked out about X" is one `task_search` instead of scrolling back through old chat.
- **A queryable plan — the TQ language.** `task_query` is a small, composable language over the graph: sources threaded through steps with `->`, set algebra (`:union`, `:intersect`, `:minus`), coalescing (`:or-else`), transitive `:closure`, predicates, and quantifiers. It describes itself through the `(schema)`, `(views)`, `(fields)`, and `(edges)` sources, so its documentation never drifts from its behavior.
- **Batteries-included views.** Ten built-in named views — `active-roots`, `orphans`, `leaf-tasks`, `stale-phases`, `plan`, `plan-frontier` (alias `frontier`), `recent`, `busy`, `hub-tasks`, `knowledge` — answer the everyday "what's ready, what's stalled, what's mine" out of the box.
- **Views you define.** Save your own queries with `task_query_write` — `(define! "name" Q)` / `(undefine! "name")` — persisted as events and recalled through `(query "name")`, shadowing built-ins of the same name.
- **Queries that write.** Mutating steps — `(:set-status! …)`, `(:set! …)`, `(:link! …)`, `(:unlink! …)` — update the graph in place, each recording an event, converging on re-run and safe to resume mid-way; sub-query operands stay read-only.
- **Read and write gate separately.** Give an agent recall and navigation without the power to change the graph; the 14 tools split into read, write, and observe, and the boundary is enforced by capability rather than by which tool names you expose.
- **History that survives a rebuild.** Every write appends one event to an append-only log and folds into a queryable projection; replaying the log reproduces the same state — your custom views and full history included — so a rebuild loses nothing.
- **Safe for many sessions at once.** Concurrent writers never tear a line, a running store learns in O(1) whether any log has moved, and every tool call refreshes from peers' writes before it runs — so a handle held open across another session's work sees that work on its next call, at no per-log cost when nothing changed.
- **Per-session focus.** Each session carries its own current-task pointer; most tools act on it unless you pass an explicit `task_id`, and `task_fork` always makes its new child current.
- **Legible output.** Rectangular projections print every selected field on every row (an absent value as `∅`, a timestamp as its raw integer plus the decoded UTC date); `(:select …)` never silently drops a column; and an unknown field, predicate, step, source, or edge errors with a "did you mean …?" suggestion.
- **Time-aware queries.** Date predicates — `(on …)`, `(since …)`, `(before …)` — window a timestamp field by UTC calendar day, alongside `(:sort FIELD :asc|:desc)` and timestamp-aware numeric comparisons over `created-ts`, `updated-ts`, and `status-ts`.
- **Rich history views.** `timeline` filters by event type, windows and pages by sequence, and renders events verbatim on demand, bounded so output stops before an overflow and prints a continuation cursor.
- **Bundled workflow prompts.** Reusable prompts — `research`, `plan`, `implement`, `validate`, `resume`, `handoff` — mounted by the host runtime and exposed to MCP clients as prompts and readable resources.
- **Nix flake** exposing the library (`packages.cairn`), the FiveAM suite and FTS5 drift gate (`checks`), and an SBCL + SQLite dev shell, for `x86_64-linux`, `aarch64-linux`, and `aarch64-darwin`.

[0.1.0]: https://github.com/kleisli-io/cairn/releases/tag/v0.1.0

<div align="center">

<img src="assets/cairn-logo.png" alt="cairn" width="720" />

# cairn

**A durable task graph your agent plans in and resumes into.**

When the session resets, the agent reloads the plan from the graph instead of reconstructing it from the conversation.

<p>
  <a href="CHANGELOG.md"><img alt="Version" src="https://img.shields.io/badge/version-0.1.0-informational.svg"></a>
  <a href="https://docs.kleisli.io/cairn"><img alt="Docs" src="https://img.shields.io/badge/docs-docs.kleisli.io-blue.svg"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-green.svg"></a>
  <img alt="MCP compatible" src="https://img.shields.io/badge/MCP-compatible-2ea44f.svg">
  <img alt="Built with Nix" src="https://img.shields.io/badge/built%20with-Nix-5277C3.svg?logo=nixos&logoColor=white">
  <img alt="Common Lisp / SBCL" src="https://img.shields.io/badge/Common%20Lisp-SBCL-333.svg">
  <img alt="SQLite FTS5" src="https://img.shields.io/badge/SQLite-FTS5-003B57.svg?logo=sqlite&logoColor=white">
</p>

<br />

</div>

An AI coding agent is sharp for the length of a session. Then the context resets and it loses the thread. It no longer knows what's already done, what it was in the middle of, or why the last few decisions went the way they did. The plan lived in the conversation, so once the conversation ends the plan is gone, and the agent either redoes finished work or stops to ask you where things stand.

cairn keeps that plan outside the conversation, as a graph of tasks the agent can read back and update. Tasks carry phases, dependencies, and status. The agent writes its plan into the graph, works against it, and after a reset reloads it instead of starting over. Because the graph is queryable, the agent asks it real questions rather than re-reading a transcript. Notes attach to tasks as the work happens, so the reasoning behind a decision is still around when you need it. cairn tracks what you're doing without prescribing how you do it.

## The name

A cairn is a pile of stones raised to mark a route across ground that holds no path of its own, a ridge or a snowfield or a stretch of moor where one direction looks like the next. A walker adds a stone and goes on. The pile stays, and shows whoever comes after which way the route ran. The word is Scottish Gaelic, *càrn*, a heap of stones.

The tool keeps that habit. Each session leaves a little more on the graph and moves on, and the next one reads the stones instead of guessing the way.

---

> ### Works with any MCP agent
>
> cairn ships as an extension for [kli](https://github.com/kleisli-io/kli), and one kli command serves it to anything that speaks the Model Context Protocol. Run `kli mcp-serve cairn`, point Claude Code, Claude Desktop, Cursor, or another MCP client at it, and cairn's tools appear as MCP tools, with its workflow prompts exposed as MCP prompts and readable resources. Using cairn doesn't mean adopting kli as your main agent; any MCP client works.

---

## Why cairn

- **Resume instead of re-explaining.** The plan lives in the graph, so a single `task_bootstrap` call drops the agent back where it left off, with its open phases, dependencies, and status intact. You don't have to brief it again after a reset.
- **The plan is queryable.** `task_query` is a small, composable language for asking the graph which phases are ready to start, what depends on a given task, and what has gone stale. The grammar can describe itself, so its documentation stays in step with its behavior.
- **History that survives a rebuild.** Each write appends one event to a log and folds into a projection you can query. Replaying the log reproduces the same state, custom views and all, so a rebuild loses nothing.
- **Reads and writes gate separately.** You can give an agent recall and navigation without giving it the power to change the graph. The boundary is enforced by capability rather than by which tool names you expose.
- **Search scoped to the work.** Observations attach to tasks and are indexed with SQLite FTS5, so finding "what we worked out about X" is a single `task_search` against the relevant tasks instead of a scroll through old chat.
- **No special host needed.** kli serves its extensions as MCP tools, so cairn runs against any MCP-compatible client.

## Quickstart

cairn runs most fully inside kli, the runtime it was built for. You can also serve it to any other MCP client, or build it from source to develop against it.

### With kli

There are two ways to add cairn to kli. Bake it into the image declaratively, or install it at runtime.

Declaratively, take cairn as a flake input and name it in your kli configuration. kli's Home Manager and NixOS modules compile the listed extensions into the image, and cairn needs SQLite on its library path:

```nix
{ inputs.cairn.url = "github:kleisli-io/cairn"; }
```

```nix
programs.kli = {
  enable = true;
  extensions = [ inputs.cairn.packages.${system}.default ];
  blessedNativeLibs = [ pkgs.sqlite ];
};
```

Imperatively, install a published release with the `kli install` subcommand. Every [release page](https://github.com/kleisli-io/cairn/releases) carries the exact command for that version; for v0.1.0:

```sh
kli install https://github.com/kleisli-io/cairn/releases/download/v0.1.0/cairn.bundle f97b592316027ef9c8c56d2072a75b6b596a0172
```

The second argument is the release's git-tree-sha1 pin: kli recomputes it over the fetched tree and refuses to install on a mismatch. It shows what it is about to add and asks before going ahead; pass `--yes` for scripts and other non-interactive use. To additionally require the release signature, add the Kleisli.IO release key — committed at [`release/trust/cairn-release.pub`](https://github.com/kleisli-io/cairn/blob/main/release/trust/cairn-release.pub) — to `trustRoots` in your kli `settings.json`; kli then fetches `cairn.bundle.sig` next to the artifact and installs only if the signature verifies.

The same install works from inside a running session as `/install <url> <git-tree-sha1>`, and the companion commands manage what you have: `/extensions` lists them, `/enable` and `/disable` toggle one, and `/uninstall` removes a runtime-installed extension. Anything baked in through Nix stays put until you edit your configuration and rebuild. To load a local build for a single run, start kli with `kli --extension <path>`.

Run `kli` in a project directory, and that working directory selects the project whose task graph cairn opens.

Driving cairn from its host gives you more than the tool surface. The agent gets cairn's tools, and you get slash commands for steering the work by hand:

- `/workon [id]` selects a task and seeds a re-entry turn, so the agent picks up where it left off.
- `/handoff [guidance]` composes and records a resumable handoff for the current task.
- `/observe <text>` records an observation without leaving the editor.
- `/task [id]` shows the current task, or switches to another by id.
- `/tasks [query]` lists recent tasks, or runs a TQ query.
- `/where` shows the resolved database, the project, and how cairn found them.

Two more things happen on their own, and a plain tool client has no way to do either. On every turn, kli folds the current task's live state into the model's view, its status, its open handoffs, and a note when another session is working the same task, so the agent stays oriented without anyone restating where things stand. And when kli compacts a long conversation, the observations and handoffs from the dropped stretch are folded into the summary, so your durable markers survive the cut rather than the model's paraphrase of them.

### From another MCP client

The same kli, built with cairn, serves the extension to any other client over stdio. Add a server entry that runs `kli mcp-serve cairn`, using the same `mcpServers` block that Claude Desktop, Cursor, and Claude Code already understand:

```json
{
  "mcpServers": {
    "cairn": {
      "command": "kli",
      "args": ["mcp-serve", "cairn"]
    }
  }
}
```

The client launches kli in your project directory, and that working directory picks the project whose task graph cairn opens. Once connected, the client lists all of cairn's tools. A first session usually goes:

1. **Orient.** Call `task_bootstrap` to load state, neighbors, open handoffs, and recent observations in one call.
2. **Record.** Call `observe` often; it's the cheapest write, and it's what later searches turn up.
3. **Ask.** Query the graph back:

```lisp
(-> (current) (:follow :phase-of) (:ids))   ; the current task's child phases
```

> One `mcp-serve` process serves a single client and exposes only the extensions you name, so pointing it at cairn gives you cairn's tools and nothing more. Capability gating carries over. The serve subject holds exactly the capabilities its exposed tools declare, so the read / write / observe split still applies over MCP.

A client reached this way gets cairn's tools plus its workflow prompts as MCP prompts and resources. The slash commands, the per-turn context, and the compaction folding do not travel over the tool protocol, since kli provides those as the host. That is why kli is the fuller home for cairn.

For the full tool reference, the complete TQ grammar, and the edge model, see **[docs.kleisli.io/cairn](https://docs.kleisli.io/cairn)**.

### Startup time with large histories

On first open, cairn reconciles the append-only task logs into its SQLite projection and stamps watermarks so later opens can skip unchanged logs. Large histories make that first reconcile visible: thousands of `events.ndjson` files or tens of megabytes of log data can take tens of seconds while the `cairn.db` projection is created or rebuilt. Once the database and watermarks are warm, startup is usually much faster.

If your workflow creates a fresh checkout or disposable workspace for every session, copy or persist the `.kli/cairn.db*` files along with `.kli/tasks/` when you want to avoid paying the first-open reconcile cost each time. The logs remain the source of truth; the database is a rebuildable projection.

### Building from source

Build the library and run its checks directly:

```sh
nix build .#cairn      # build the compiled library
nix flake check        # run the FiveAM suite + the FTS5 drift gate
```

## The model

cairn keeps two things, a **task graph** and an **observation store**.

- **Tasks** are the nodes. Each one carries a human-readable slug, date-prefixed and slugified, like `2026-06-20-ship-the-thing`.
- **Edges** are typed. `phase-of` is the structural parent/child link, and a task has at most one parent. `depends-on` and `related` are lateral. A plan is a task DAG, where phases are the children and `depends-on` sets their order.
- **Observations** are freeform notes appended to a task and stored as events. They are cheap, so you record them as you go.
- **Durability.** Every write appends one event to the log and folds into a queryable projection. Replay the log and the same projection comes back, your own views and full history included.
- **The current task is per session.** Each session keeps its own current-task pointer, and most tools act on it unless you pass an explicit `task_id`. `task_create` adopts the current task only when none is set; `task_bootstrap` with an explicit `task_id` switches the pointer to that task (orienting focuses it); `task_fork` always makes its new child current.

## The tools

cairn exposes a fixed set of tools, capability-gated into read, write, and observe:

| Group | Tools |
|---|---|
| **Record** | `observe`, `handoff` |
| **Lifecycle** | `task_create`, `task_fork`, `task_update_status`, `task_set_metadata` |
| **Edges** | `task_link`, `task_sever` |
| **Read** | `task_get`, `timeline`, `task_search` |
| **Query / Orient** | `task_query`, `task_query_write`, `task_bootstrap` |

`task_bootstrap` is the one-call re-entry point for a session. It returns state, neighbors, open handoffs, recent observations, and a short readout of what other sessions are doing.

### task_query (TQ) — query the task graph

A TQ query is a **source** form, optionally threaded through **steps** with `->`. Use `task_query` for task identity/name/slug/status/metadata lookup and graph relationships. `task_search` is different: it searches observation text only, not task names or slugs. The grammar includes set algebra (`:union`, `:intersect`, `:minus`), coalescing (`:or-else`), transitive `:closure`, predicates, and quantifiers.

```lisp
(-> (all) (:where (matches :slug "compaction")) (:select :slug :status)) ; find tasks by slug
(-> (current) (:follow :phase-of) (:ids))          ; the current task's child phases
(-> (active) (:where (> :obs-count 10)) (:count))  ; active tasks with lots of observations
```

> TQ describes itself. Probe `(schema)` for sources, steps, predicates, and write forms (steps and predicates with their argument signatures), `(views)` for named views, `(fields)` for queryable fields, and `(edges)` for edge types. Each probe answers as a query you can thread through the same steps, so the reflection can't fall out of sync with the behavior. An unknown name — a field, predicate, step, source, or edge — errors with a nearest-match suggestion rather than misfiring silently, and timestamps are universal-time so a calendar intent like `(on :updated-ts "2026-06-24")` is one predicate. The read/write split is a capability gate. `task_query` refuses mutating `!`-forms, and `task_query_write` accepts them.

Named views ship built in and are reached through the `query` source, as in `(query "plan-frontier")`. They include `plan-frontier` (the phases ready to start), `stale-phases`, `busy`, `active-roots`, and more. You can add your own with `task_query_write`, where `(define! "name" Q)` stores a view as an event so it replays like any other fact. The full grammar, every tool, and the edge model live at **[docs.kleisli.io/cairn](https://docs.kleisli.io/cairn)**.

## Requirements

- **SBCL.** cairn is written in Common Lisp.
- **SQLite with FTS5.** This one is mandatory. The observation index is built on FTS5, and the build runs a gate that fails if the linked SQLite doesn't provide it.
- **[kli](https://github.com/kleisli-io/kli)** as the host runtime, plus **[cl-deps](https://github.com/kleisli-io/cl-deps)**, both wired in as flake inputs.

cairn registers as a kli extension via `defextension cairn`. It requires kli's `config/v1` and `events/v1` capabilities and provides its tools, bundled prompts, and context/compaction effects.

## Flake outputs

Across `x86_64-linux`, `aarch64-linux`, and `aarch64-darwin`:

| Output | What it is |
|---|---|
| `packages.<system>.cairn` (also `default`) | the compiled library |
| `checks.<system>.library` | the library, as a check |
| `checks.<system>.tests` | the FiveAM test suite |
| `checks.<system>.drift` | the FTS5 build gate |
| `devShells.<system>.default` | a shell with SBCL and SQLite |

## Learn more

- **Documentation:** [docs.kleisli.io/cairn](https://docs.kleisli.io/cairn) covers every tool, the full TQ grammar, the edge model, and the working method.
- **Release notes:** [`CHANGELOG.md`](CHANGELOG.md).

## License

cairn is released under the [MIT License](LICENSE).

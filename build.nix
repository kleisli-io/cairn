{ pkgs, buildLisp, lisp, kli }:

let
  # Serial load order: the package definition first, the extension marker last,
  # everything else alphabetical. No subdirectories are descended.
  srcs = [
    ./src/package.lisp
    ./src/paths.lisp
    ./src/store.lisp
    ./src/model.lisp
    ./src/validation.lisp
    ./src/write.lisp
    ./src/ndjson.lisp
    ./src/reconcile.lisp
    ./src/session.lisp
    ./src/current-task.lisp
    ./src/tools.lisp
    ./src/search.lisp
    ./src/query.lisp
    ./src/context.lisp
    ./src/compaction.lisp
    ./src/commands.lisp
    ./src/extension.lisp
  ];

  testSrcs = [
    ./t/package.lisp
    ./t/cairn-store.lisp
    ./t/cairn-locality.lisp
    ./t/cairn-events.lisp
    ./t/cairn-convergence.lisp
    ./t/cairn-ndjson.lisp
    ./t/cairn-log-mirror.lisp
    ./t/cairn-reconcile.lisp
    ./t/cairn-merge-convergence.lisp
    ./t/cairn-session.lisp
    ./t/cairn-tools.lisp
    ./t/cairn-search.lisp
    ./t/cairn-query.lisp
    ./t/cairn-bootstrap.lisp
    ./t/cairn-context.lisp
    ./t/cairn-commands.lisp
    ./t/cairn-compaction.lisp
  ];

  resourcesAttr = {
    "kli/cairn/maxims" = ./src/maxims;
    "kli/cairn/prompts" = ./src/prompts;
    "kli/cairn/skills" = ./src/skills;
  };

  # Fails the build unless the SQLite the binding links was compiled with FTS5.
  # The full-text index the store relies on cannot exist otherwise.
  fts5Gate = pkgs.runCommand "cairn-fts5-gate" { nativeBuildInputs = [ pkgs.sqlite ]; } ''
    options=$(sqlite3 :memory: 'PRAGMA compile_options;')
    if ! printf '%s\n' "$options" | grep -qx 'ENABLE_FTS5'; then
      echo >&2
      echo "The linked SQLite was built without FTS5 (ENABLE_FTS5 absent from" >&2
      echo "PRAGMA compile_options); the store requires full-text search." >&2
      exit 1
    fi
    touch $out
  '';

  library = buildLisp.library {
    name = "cairn";

    resources = resourcesAttr;

    deps = [
      kli
      lisp.sqlite
    ];

    srcs = srcs;

    tests = {
      deps = [ lisp.fiveam ];
      srcs = testSrcs;
      expression = "(fiveam:run! 'kli/cairn/tests::all)";
    };

    passthru = {
      name = "cairn";
      manifestSymbol = "kli/cairn:*cairn-extension-manifest*";
      driftGate = fts5Gate;
      # Self-reference so consumers can select the library FASL explicitly.
      library = library;
    };
  };
in
library

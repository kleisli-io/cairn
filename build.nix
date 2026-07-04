{ pkgs, buildLisp, lisp, kli }:

let
  lib = pkgs.lib;

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
    ./t/store.lisp
    ./t/locality.lisp
    ./t/events.lisp
    ./t/convergence.lisp
    ./t/ndjson.lisp
    ./t/log-mirror.lisp
    ./t/concurrent-append.lisp
    ./t/reconcile.lisp
    ./t/freshness-gate.lisp
    ./t/merge-convergence.lisp
    ./t/session.lisp
    ./t/tools.lisp
    ./t/reconcile-trigger.lisp
    ./t/search.lisp
    ./t/query.lisp
    ./t/bootstrap.lisp
    ./t/context.lisp
    ./t/commands.lisp
    ./t/compaction.lisp
  ];

  resourcesAttr = {
    "kli/cairn/prompts" = ./src/prompts;
  };

  # cairn.asd generated from srcs (drift-checked) so the ASDF loader and the Nix
  # build share one load order. No :depends-on: kli and sqlite are already in the
  # host image when it loads cairn as a directory unit.
  asd =
    let
      rootStr = toString ./.;
      relativize = s:
        lib.removeSuffix ".lisp" (lib.removePrefix (rootStr + "/") (toString s));
      componentForms =
        lib.concatMapStringsSep "\n               " (p: ''(:file "${relativize p}")'') srcs;
      asdText = ''
        ;;;; cairn system definition -- GENERATED; do not hand-edit.
        (defsystem "cairn"
          :description "SQLite-backed task graph and observation store, a kli extension"
          :version (:read-file-form "version.sexp")
          :author "Kleisli.IO"
          :license "MIT"
          :serial t
          :components (${componentForms}))
      '';
    in
    pkgs.writeText "cairn.asd" asdText;

  # Gate the build: the linked SQLite must carry FTS5, and the committed
  # cairn.asd must match what srcs generates.
  driftGate = pkgs.runCommand "cairn-drift-gate" { nativeBuildInputs = [ pkgs.sqlite ]; } ''
    options=$(sqlite3 :memory: 'PRAGMA compile_options;')
    if ! printf '%s\n' "$options" | grep -qx 'ENABLE_FTS5'; then
      echo >&2
      echo "The linked SQLite was built without FTS5 (ENABLE_FTS5 absent from" >&2
      echo "PRAGMA compile_options); the store requires full-text search." >&2
      exit 1
    fi
    if ! diff -u ${./cairn.asd} ${asd}; then
      echo >&2
      echo "cairn.asd is out of sync with the source list in build.nix." >&2
      echo "Regenerate it from the build and commit the result." >&2
      exit 1
    fi
    touch $out
  '';

  # Clean-image witness: the relocatable kli bundle (which does not bundle cairn
  # but carries libsqlite in its lib/) installs cairn's real source over a
  # loopback origin, then a fresh `kli mcp-serve cairn` loads the placed directory
  # unit via ASDF in declared order and serves its tools, opening the store
  # against the bundled libsqlite so FTS5 is exercised at runtime.
  serveE2E = pkgs.runCommand "cairn-serve-e2e"
    { nativeBuildInputs = [ pkgs.python3 pkgs.git ]; } ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    python3 ${./t/e2e/serve.py} \
      --kli ${kli.kliRelocatable}/bin/kli \
      --asd ${./cairn.asd} \
      --version ${./version.sexp} \
      --src ${./src}
    touch $out
  '';

  # Tracked source only: no compiled *.fasl or stray files, so the pin follows
  # the source, not the builder's disk.
  bundleSrc = lib.cleanSourceWith {
    src = ./src;
    filter = path: type:
      type == "directory"
      || lib.hasSuffix ".lisp" path
      || lib.hasSuffix ".md" path
      || lib.hasSuffix ".keep" path;
  };

  # Release artifact: cairn.bundle, its git write-tree pin, and checksums.txt.
  # Built twice and compared to assert byte-determinism.
  releaseArtifact = pkgs.runCommand "cairn-release-artifact"
    { nativeBuildInputs = [ pkgs.python3 pkgs.git ]; } ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME" "$out" "$TMPDIR/replica"
    build() {
      python3 ${./release/bundle.py} \
        --asd ${./cairn.asd} --version ${./version.sexp} \
        --src ${bundleSrc} --out "$1"
    }
    build "$out"
    build "$TMPDIR/replica"
    cmp "$out/cairn.bundle" "$TMPDIR/replica/cairn.bundle"
    cmp "$out/pin" "$TMPDIR/replica/pin"
    ( cd "$out" && sha256sum cairn.bundle > checksums.txt )
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
      inherit asd driftGate serveE2E releaseArtifact;
      # Self-reference so consumers can select the library FASL explicitly.
      library = library;
    };
  };
in
library

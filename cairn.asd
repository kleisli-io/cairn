;;;; cairn system definition -- GENERATED; do not hand-edit.
(defsystem "cairn"
  :description "SQLite-backed task graph and observation store, a kli extension"
  :version (:read-file-form "version.sexp")
  :author "Kleisli.IO"
  :license "MIT"
  :serial t
  :components ((:file "src/package")
               (:file "src/paths")
               (:file "src/store")
               (:file "src/model")
               (:file "src/validation")
               (:file "src/write")
               (:file "src/ndjson")
               (:file "src/reconcile")
               (:file "src/session")
               (:file "src/current-task")
               (:file "src/tools")
               (:file "src/search")
               (:file "src/query")
               (:file "src/context")
               (:file "src/compaction")
               (:file "src/commands")
               (:file "src/extension")))

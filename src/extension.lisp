(in-package #:kli/cairn)

(defclass cairn-store (live-object)
  ((path :initarg :path :initform nil :accessor cairn-store-path)))

(defun make-cairn-store ()
  (make-instance 'cairn-store :id :cairn-store))

(defun find-cairn-store (context)
  (find-live-object (context-registry context) :cairn-store))

(defun cairn-open-db (protocol contribution context)
  "Resolve the database path, open the store, register the active project, and
stash the handle, its guard mutex, and the project id on PROTOCOL. Returns the
prior handle for symmetric restore."
  (declare (ignore contribution))
  (multiple-value-bind (path step) (resolve-cairn-db-location context)
    (let ((previous (protocol-storage protocol +cairn-db-key+)))
      (ensure-directories-exist path)
      (when (eq step :project)
        (ensure-db-gitignore path)
        (ensure-log-gitattributes path))
      (let ((handle (open-cairn-store path))
            (project (resolve-project context)))
        (when (eq step :project) (reconcile-store handle))
        (ensure-project-row handle project)
        (setf (protocol-storage protocol +cairn-db-key+) handle
              (protocol-storage protocol +cairn-lock-key+)
              (sb-thread:make-mutex :name "cairn-store")
              (protocol-storage protocol +cairn-project-key+) (cp-project-id project))
        (let ((store (find-cairn-store context)))
          (when store
            (setf (cairn-store-path store) path))))
      previous)))

(defun cairn-close-db (protocol contribution context)
  "Close the database handle and drop it, its mutex, and the project id from
PROTOCOL's storage."
  (declare (ignore contribution context))
  (let ((handle (protocol-storage protocol +cairn-db-key+)))
    (when handle
      (close-cairn-store handle)))
  (remhash +cairn-db-key+ (protocol-storage-table protocol))
  (remhash +cairn-lock-key+ (protocol-storage-table protocol))
  (remhash +cairn-project-key+ (protocol-storage-table protocol)))

(defextension cairn
  (:requires
   (capability config :contract config/v1)
   (capability events :contract events/v1))
  (:provides
   (live-object cairn-store (make-cairn-store))
   (effect cairn-store-db
     #'cairn-open-db
     #'cairn-close-db)
   (event-type :cairn/observation)
   (tool observe
     :label "Observe"
     :description "Record a freeform observation on the current task. The cheapest call; use it liberally as the work heartbeat."
     :parameters '(:object (:text :string)
                   (:task_id :string :optional t))
     :runner #'run-observe
     :metadata '(:capabilities (:cairn/observe)))
   (tool task_create
     :label "Create task"
     :description "Create a top-level task. Adopts it as the current task only when none is set."
     :parameters '(:object (:name :string)
                   (:description :string :optional t))
     :runner #'run-task-create
     :metadata '(:capabilities (:cairn/write)))
   (tool task_fork
     :label "Fork subtask"
     :description "Create a child task linked to a parent (default edge phase-of) and make the child current."
     :parameters '(:object (:name :string)
                   (:from :string :optional t)
                   (:edge_type :string :optional t)
                   (:description :string :optional t))
     :runner #'run-task-fork
     :metadata '(:capabilities (:cairn/write)))
   (tool task_link
     :label "Link tasks"
     :description "Create a typed edge from the current task to a target. edge_type is one of phase-of, depends-on, related."
     :parameters '(:object (:target_id :string)
                   (:edge_type :string)
                   (:task_id :string :optional t))
     :runner #'run-task-link
     :metadata '(:capabilities (:cairn/write)))
   (tool task_sever
     :label "Sever edge"
     :description "Remove a typed edge from the current task to a target."
     :parameters '(:object (:target_id :string)
                   (:edge_type :string)
                   (:task_id :string :optional t))
     :runner #'run-task-sever
     :metadata '(:capabilities (:cairn/write)))
   (tool task_set_metadata
     :label "Set metadata"
     :description "Set a free key/value on a task, for example display-name, phase, objective, acceptance, or tags."
     :parameters '(:object (:key :string)
                   (:value :string)
                   (:task_id :string :optional t))
     :runner #'run-task-set-metadata
     :metadata '(:capabilities (:cairn/write)))
   (tool task_update_status
     :label "Update status"
     :description "Set task status: open, active, completed, abandoned, or blocked. Idempotent; pass reopen=true to revive a completed task."
     :parameters '(:object (:status :string)
                   (:task_id :string :optional t)
                   (:reopen :boolean :optional t))
     :runner #'run-task-update-status
     :metadata '(:capabilities (:cairn/write)))
   (tool handoff
     :label "Handoff"
     :description "Record a resumable handoff for the current task. The summary is the load-bearing field; an optional path points at a written note."
     :parameters '(:object (:summary :string)
                   (:path :string :optional t)
                   (:task_id :string :optional t))
     :runner #'run-handoff
     :metadata '(:capabilities (:cairn/write)))
   (tool task_search
     :label "Search tasks"
     :description "Full-text ranked search over observations. Returns matching tasks with a snippet."
     :parameters '(:object (:query :string)
                   (:limit :integer :optional t)
                   (:task_id :string :optional t))
     :runner #'run-task-search
     :metadata '(:capabilities (:cairn/read)))
   (tool task_get
     :label "Get task"
     :description "Read computed task state: status, description, parent, children, edges, metadata, and recent observations."
     :parameters '(:object (:task_id :string :optional t))
     :runner #'run-task-get
     :metadata '(:capabilities (:cairn/read)))
   (tool timeline
     :label "Timeline"
     :description "Recent events for a task, most recent first."
     :parameters '(:object (:task_id :string :optional t)
                   (:limit :integer :optional t))
     :runner #'run-timeline
     :metadata '(:capabilities (:cairn/read)))
   (tool task_query
     :label "Query tasks"
     :description "Run a read-only query over the task graph and return text. The query argument is a single s-expression in cairn's query language (TQ); it is a Lisp form, not a bare word, so names and probes are always wrapped in parens. Pass a reflective form on its own to learn the language: (views) lists the named views, (schema) the sources and steps, (fields) the queryable fields, (edges) the edge types. To run a named view, wrap its name as (query \"plan\") or (query \"plan-frontier\") — passing bare plan or views is a parse error. Otherwise a query is a SOURCE optionally threaded through STEPS with ->, for example (-> (current) (:follow :phase-of) (:ids)) or (-> (active) (:where (> :obs-count 10)) (:count)); transformer steps compose (node-set to node-set) and shaper steps terminate into a value. Every form yields a value or a structured error, never a crash or a silent no-op. The !-forms (mutations and define!) are refused here; use task_query_write."
     :parameters '(:object (:query :string))
     :runner #'run-task-query
     :metadata '(:capabilities (:cairn/read)))
   (tool task_query_write
     :label "Query tasks (write)"
     :description "The write surface for the same query language as task_query, accepting the !-forms it refuses: mutating steps that write per task (kind=mutation in (schema), e.g. (-> (query \"plan-frontier\") (:set-status! \"completed\"))) and view definitions (define! / undefine!). A mutation step records an append-only event for each task and returns the set, so (:count) after it reports how many it touched; effects converge on re-run, and sub-query operands stay read-only. (define! \"name\" Q) records Q as a reusable named view resolvable via (query \"name\"). Read-only queries run here too, but prefer task_query for them."
     :parameters '(:object (:query :string))
     :runner #'run-task-query-write
     :metadata '(:capabilities (:cairn/write)))
   (tool task_bootstrap
     :label "Bootstrap task"
     :description "Orient on a task in one call: its state, neighbors, open handoffs, recent observations, and what other sessions are currently doing. Adopts the task as current only when none is set."
     :parameters '(:object (:task_id :string :optional t))
     :runner #'run-task-bootstrap
     :metadata '(:capabilities (:cairn/read)))
   (effect cairn-context
     #'install-cairn-context
     #'uninstall-cairn-context)
   (effect cairn-commands
     #'register-cairn-commands
     #'unregister-cairn-commands)
   (effect cairn-compaction
     #'install-cairn-compaction
     #'uninstall-cairn-compaction)))

(register-extension-resource-roots :cairn
                                   :prompts "kli/cairn/prompts"
                                   :skills "kli/cairn/skills")

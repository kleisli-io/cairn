(in-package #:kli/cairn/tests)
(in-suite all)

;;; task_query: the composable graph-query surface over the projection. Seeds run
;;; through the real tool boundary; assertions read the rendered text, so these
;;; also prove nothing but a string crosses back.

(defun run-query (protocol context string)
  (ext:invoke-tool protocol :task_query (list :query string) context))

(defun query-text (protocol context string)
  (tool-text (run-query protocol context string)))

(defun node-query (slug &rest steps)
  (format nil "(-> (node ~S)~{ ~A~})" slug steps))

(defun run-query-write (protocol context string)
  (ext:invoke-tool protocol :task_query_write (list :query string) context))

(defun query-write-text (protocol context string)
  (tool-text (run-query-write protocol context string)))

(test follow-and-back-honor-phase-of-direction
  "A forked child is reachable forward via :follow :phase-of from the parent and
backward via :back :phase-of from the child."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "the structural parent task") context)
    (let ((parent (cairn:current-task-id context)))
      (ext:invoke-tool protocol :task_fork
                       (list :name "the structural child task") context)
      (let ((child (cairn:current-task-id context)))
        (is (search child (query-text protocol context
                                      (node-query parent "(:follow :phase-of)" "(:ids)")))
            "follow phase-of from the parent lists the child")
        (is (search parent (query-text protocol context
                                       (node-query child "(:back :phase-of)" "(:ids)")))
            "back phase-of from the child lists the parent")))))

(test depends-on-edges-traverse-both-directions
  "A lateral depends-on edge is followed forward to its target and backward to
its source."
  (with-cairn-protocol (context protocol)
    (let ((a (created-slug
              (ext:invoke-tool protocol :task_create
                               (list :name "depends edge tail task") context)))
          (b (created-slug
              (ext:invoke-tool protocol :task_create
                               (list :name "depends edge head task") context))))
      (ext:invoke-tool protocol :task_link
                       (list :target_id b :edge_type "depends-on" :task_id a) context)
      (is (search b (query-text protocol context
                                (node-query a "(:follow :depends-on)" "(:ids)")))
          "follow depends-on from the source reaches the target")
      (is (search a (query-text protocol context
                                (node-query b "(:back :depends-on)" "(:ids)")))
          "back depends-on from the target reaches the source"))))

(test active-and-dormant-split-on-status
  "A completed task leaves (active) and appears in (dormant); a live one is the
reverse."
  (with-cairn-protocol (context protocol)
    (let ((live (created-slug
                 (ext:invoke-tool protocol :task_create
                                  (list :name "the live ongoing effort") context)))
          (done (created-slug
                 (ext:invoke-tool protocol :task_create
                                  (list :name "the finished archived effort") context))))
      (ext:invoke-tool protocol :task_update_status
                       (list :status "completed" :task_id done) context)
      (let ((active (query-text protocol context "(active)"))
            (dormant (query-text protocol context "(dormant)")))
        (is (search live active) "the live task is active")
        (is (not (search done active)) "the completed task is not active")
        (is (search done dormant) "the completed task is dormant")
        (is (not (search live dormant)) "the live task is not dormant")))))

(test select-projects-named-fields
  "(:select ...) renders the requested fields with their values."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "render the cairn projection task") context)
    (let ((text (query-text protocol context
                            "(-> (node \"cairn\") (:select :display-name :status))")))
      (is (search "status" text) "the projection names the status field")
      (is (search "active" text) "the projected status value is active"))))

(test plan-frontier-tracks-dependency-readiness
  "plan-frontier shows only phases whose dependencies are done; completing a
dependency moves its dependents onto the frontier."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "the dependency frontier parent") context)
    (let ((parent (cairn:current-task-id context)))
      (ext:invoke-tool protocol :task_fork
                       (list :name "groundwork phase alpha task") context)
      (let ((p1 (cairn:current-task-id context)))
        (ext:invoke-tool protocol :task_fork
                         (list :name "dependent phase beta task" :from parent) context)
        (let ((p2 (cairn:current-task-id context)))
          (ext:invoke-tool protocol :task_link
                           (list :target_id p1 :edge_type "depends-on" :task_id p2) context)
          (setf (cairn:current-task-id context) parent)
          (let ((before (query-text protocol context "(query \"plan-frontier\")")))
            (is (search p1 before) "the unblocked phase is on the frontier")
            (is (not (search p2 before)) "the blocked phase is held back"))
          (ext:invoke-tool protocol :task_update_status
                           (list :status "completed" :task_id p1) context)
          (let ((after (query-text protocol context "(query \"frontier\")")))
            (is (search p2 after) "the dependent phase joins the frontier once unblocked")
            (is (not (search p1 after)) "the completed phase leaves the frontier")))))))

(test knowledge-is-a-cycle-safe-transitive-closure
  "knowledge walks the forward closure over lateral edges and terminates on a
cycle."
  (with-cairn-protocol (context protocol)
    (let ((a (created-slug
              (ext:invoke-tool protocol :task_create
                               (list :name "knowledge alpha origin node") context)))
          (b (created-slug
              (ext:invoke-tool protocol :task_create
                               (list :name "knowledge beta middle node") context)))
          (c (created-slug
              (ext:invoke-tool protocol :task_create
                               (list :name "knowledge gamma final node") context))))
      (ext:invoke-tool protocol :task_link
                       (list :target_id b :edge_type "related" :task_id a) context)
      (ext:invoke-tool protocol :task_link
                       (list :target_id c :edge_type "related" :task_id b) context)
      (ext:invoke-tool protocol :task_link
                       (list :target_id a :edge_type "related" :task_id c) context)
      (setf (cairn:current-task-id context) a)
      (let ((text (query-text protocol context "(query \"knowledge\")")))
        (is (search b text) "the one-hop neighbour is in the closure")
        (is (search c text) "the two-hop neighbour is in the closure")))))

(test an-unknown-named-query-lists-the-available-names
  (with-cairn-protocol (context protocol)
    (let ((result (run-query protocol context "(query \"nope\")")))
      (is (ext:tool-result-error-p result) "an unknown view is an error")
      (is (search "active-roots" (tool-text result))
          "the error enumerates the available views"))))

(test malformed-and-unsupported-queries-fail-cleanly
  "Malformed syntax, mutation steps, pattern sources, and unknown steps all
return a structured error rather than a backtrace."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "the rejection probe task") context)
    (dolist (q '("((("
                 "(-> (current) (:complete!))"
                 "(activate \"x\")"
                 "(-> (all) (:bogus-step))"))
      (is (ext:tool-result-error-p (run-query protocol context q))
          "the query is rejected with a structured error"))))

(test count-ids-and-group-by-render-expected-shapes
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "the first counted item") context)
    (ext:invoke-tool protocol :task_create
                     (list :name "the second counted item") context)
    (is (string= "2" (query-text protocol context "(-> (all) (:count))"))
        "count returns the cardinality as a bare number")
    (is (search "active"
                (query-text protocol context "(-> (active) (:group-by :status))"))
        "group-by status names the active bucket")))

(test the-runner-returns-text-content-only
  "A bare node-set result crosses the boundary as text, never a live object."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "a strict leaf probe task") context)
    (let ((result (run-query protocol context "(-> (all))")))
      (is (not (ext:tool-result-error-p result)) "a well-formed query succeeds")
      (is (stringp (tool-text result)) "the result is text"))))

(test forked-from-traverses-the-structural-fibration
  "phase-of and forked-from both fold into the parent FK, so a child reached by
:follow :phase-of is equally reached by :follow :forked-from — the formerly
silent-empty traversal now honestly walks the fibration."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "the fibration parent task") context)
    (let ((parent (cairn:current-task-id context)))
      (ext:invoke-tool protocol :task_fork
                       (list :name "the fibration child task") context)
      (let ((child (cairn:current-task-id context)))
        (is (search child (query-text protocol context
                                      (node-query parent "(:follow :forked-from)" "(:ids)")))
            "follow forked-from from the parent reaches the structural child")))))

(test an-unknown-edge-type-is-a-structured-error
  "An edge type outside the model's vocabulary errors rather than silently
yielding an empty traversal — the model can tell a typo from no matches."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "the unknown edge probe task") context)
    (is (ext:tool-result-error-p
         (run-query protocol context
                    (node-query "unknown" "(:follow :imaginary-edge)" "(:ids)")))
        "an unrecognized edge type is rejected")))

(test numeric-comparison-on-a-text-field-is-an-error
  "A numeric comparison against a textual field is ill-typed and errors instead
of quietly matching nothing."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "the comparison probe task") context)
    (is (ext:tool-result-error-p
         (run-query protocol context "(-> (all) (:where (> :status 3)))"))
        "comparing a text field numerically is rejected")
    (is (not (ext:tool-result-error-p
              (run-query protocol context "(-> (all) (:where (> :obs-count -1)))")))
        "comparing a numeric field is accepted")))

(test matches-predicate-is-field-aware
  "(matches FIELD substr) searches within the named field; :slug matches the
slug, a content field matches its value."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "the matchable haystack task"
                           :description "a distinctive needle in the description")
                     context)
    (is (search "haystack"
                (query-text protocol context
                            "(-> (all) (:where (matches :slug \"haystack\")) (:ids))"))
        "matches on :slug finds the task by its slug substring")
    (is (search "haystack"
                (query-text protocol context
                            "(-> (all) (:where (matches :description \"needle\")) (:ids))"))
        "matches on :description finds the task by its description substring")))

(test regularized-syntax-rejects-bare-keyword-operators
  "After regularization every operator is a form; the old bare-keyword source
and steps are no longer accepted."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "the regularization probe task") context)
    (dolist (q '(":all" "(-> (all) :ids)" "(-> (all) :count)"))
      (is (ext:tool-result-error-p (run-query protocol context q))
          "a bare-keyword operator is rejected"))))

(defun %seed-active-and-dormant (context protocol)
  "Seed one live task and one completed task; return (values live-slug done-slug)."
  (let ((live (created-slug
               (ext:invoke-tool protocol :task_create
                                (list :name "the set algebra live task") context)))
        (done (created-slug
               (ext:invoke-tool protocol :task_create
                                (list :name "the set algebra done task") context))))
    (ext:invoke-tool protocol :task_update_status
                     (list :status "completed" :task_id done) context)
    (values live done)))

(test set-union-is-the-deduped-combination
  "(active) ∪ (dormant) is every task, counted once."
  (with-cairn-protocol (context protocol)
    (%seed-active-and-dormant context protocol)
    (is (string= "2" (query-text protocol context
                                 "(-> (active) (:union (dormant)) (:count))"))
        "the union of the status partition is the whole set")))

(test set-intersect-keeps-only-common-tasks
  "Disjoint sets intersect to nothing; a set intersected with a superset is itself."
  (with-cairn-protocol (context protocol)
    (%seed-active-and-dormant context protocol)
    (is (string= "0" (query-text protocol context
                                 "(-> (active) (:intersect (dormant)) (:count))"))
        "active and dormant are disjoint")
    (is (string= "1" (query-text protocol context
                                 "(-> (all) (:intersect (active)) (:count))"))
        "all ∩ active is active")))

(test set-minus-removes-the-operand
  "(all) minus (active) leaves exactly the dormant tasks."
  (with-cairn-protocol (context protocol)
    (multiple-value-bind (live done) (%seed-active-and-dormant context protocol)
      (let ((text (query-text protocol context
                              "(-> (all) (:minus (active)) (:ids))")))
        (is (search done text) "the dormant task survives the difference")
        (is (not (search live text)) "the active task is removed")))))

(test a-set-operation-operand-must-be-a-node-set
  "A sub-query that terminates into a scalar cannot be a set operand."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "the operand shape probe") context)
    (is (ext:tool-result-error-p
         (run-query protocol context "(-> (all) (:union (-> (all) (:count))))"))
        "a count operand is rejected")))

(test a-set-operation-operand-is-read-only
  "A mutation inside an operand is refused even though it is structurally a
node-set transformer."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "the operand mutation probe") context)
    (is (ext:tool-result-error-p
         (run-query protocol context "(-> (all) (:union (-> (all) (:complete!))))"))
        "a mutation step inside an operand is refused")))

(defun %seed-dependency-fan (context protocol)
  "A root task depending on two others — one completed, one still live. Returns
(values root-slug done-slug live-slug)."
  (let ((root (created-slug
               (ext:invoke-tool protocol :task_create
                                (list :name "quantifier fan root task") context)))
        (done (created-slug
               (ext:invoke-tool protocol :task_create
                                (list :name "quantifier fan done dependency") context)))
        (live (created-slug
               (ext:invoke-tool protocol :task_create
                                (list :name "quantifier fan live dependency") context))))
    (ext:invoke-tool protocol :task_link
                     (list :target_id done :edge_type "depends-on" :task_id root) context)
    (ext:invoke-tool protocol :task_link
                     (list :target_id live :edge_type "depends-on" :task_id root) context)
    (ext:invoke-tool protocol :task_update_status
                     (list :status "completed" :task_id done) context)
    (values root done live)))

(test quantifiers-evaluate-a-predicate-over-a-traversal
  "all/any/none test the inner predicate over the tasks one hop from the focus
node; a mixed dependency set distinguishes them, and completing the rest flips
`all`."
  (with-cairn-protocol (context protocol)
    (multiple-value-bind (root done live) (%seed-dependency-fan context protocol)
      (declare (ignore done))
      (let ((all-done (query-text protocol context
                        (node-query root "(:where (all (:follow :depends-on) (= :status \"completed\")))" "(:ids)")))
            (any-done (query-text protocol context
                        (node-query root "(:where (any (:follow :depends-on) (= :status \"completed\")))" "(:ids)")))
            (none-done (query-text protocol context
                        (node-query root "(:where (none (:follow :depends-on) (= :status \"completed\")))" "(:ids)"))))
        (is (not (search root all-done)) "not every dependency is completed, so `all` excludes the root")
        (is (search root any-done) "one dependency is completed, so `any` includes the root")
        (is (not (search root none-done)) "a completed dependency exists, so `none` excludes the root"))
      (ext:invoke-tool protocol :task_update_status
                       (list :status "completed" :task_id live) context)
      (is (search root (query-text protocol context
                         (node-query root "(:where (all (:follow :depends-on) (= :status \"completed\")))" "(:ids)")))
          "with every dependency completed, `all` includes the root"))))

(test a-quantifier-over-an-empty-traversal-is-vacuous
  "A focus node with no neighbors makes `all` and `none` vacuously true and `any`
false."
  (with-cairn-protocol (context protocol)
    (let ((leaf (created-slug
                 (ext:invoke-tool protocol :task_create
                                  (list :name "the dependency-free leaf probe task") context))))
      (is (search leaf (query-text protocol context
                         (node-query leaf "(:where (all (:follow :depends-on) (= :status \"completed\")))" "(:ids)")))
          "all over no dependencies is vacuously true")
      (is (search leaf (query-text protocol context
                         (node-query leaf "(:where (none (:follow :depends-on) (= :status \"completed\")))" "(:ids)")))
          "none over no dependencies is vacuously true")
      (is (not (search leaf (query-text protocol context
                             (node-query leaf "(:where (any (:follow :depends-on) (= :status \"completed\")))" "(:ids)"))))
          "any over no dependencies is false"))))

(test count-of-a-traversal-is-a-numeric-field-expression
  "(count TRAV) yields the cardinality of a relative traversal in either
direction, usable as the left side of a numeric comparison."
  (with-cairn-protocol (context protocol)
    (multiple-value-bind (root done live) (%seed-dependency-fan context protocol)
      (declare (ignore live))
      (is (search root (query-text protocol context
                         (node-query root "(:where (> (count (:follow :depends-on)) 1))" "(:ids)")))
          "the root has more than one dependency")
      (is (not (search root (query-text protocol context
                              (node-query root "(:where (> (count (:follow :depends-on)) 2))" "(:ids)"))))
          "the root does not have more than two dependencies")
      (is (search done (query-text protocol context
                         (node-query done "(:where (> (count (:back :depends-on)) 0))" "(:ids)")))
          "the completed dependency has an incoming depends-on edge"))))

(test a-quantifier-edge-is-validated-even-over-an-empty-set
  "An unknown edge inside a quantifier errors even when the filtered set is empty —
the edge is a property of the query, not the data."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "the quantifier edge probe task") context)
    (is (ext:tool-result-error-p
         (run-query protocol context
                    "(-> (node \"no-such-task-anywhere\") (:where (all (:follow :imaginary-edge) (has :slug))))"))
        "an unknown quantifier edge is rejected even with no rows to test")))

(test define-is-refused-on-the-read-surface-and-allowed-on-the-write-surface
  "A define! form is a mutation: refused under the read-only task_query, accepted
under task_query_write, where it returns the defined query's tasks."
  (with-cairn-protocol (context protocol)
    (let ((target (created-slug
                   (ext:invoke-tool protocol :task_create
                                    (list :name "the view definition probe task") context))))
      (is (ext:tool-result-error-p
           (run-query protocol context "(define! \"my-active\" (active))"))
          "define! is refused on the read surface")
      (let ((result (run-query-write protocol context "(define! \"my-active\" (active))")))
        (is (not (ext:tool-result-error-p result)) "define! is accepted on the write surface")
        (is (search target (tool-text result)) "define! returns the defined query's tasks")))))

(test a-user-view-shadows-a-builtin-and-undefine-restores-it
  "A define! over a built-in name shadows it in the one resolver; undefine!
removes the user view and the built-in reappears."
  (with-cairn-protocol (context protocol)
    (let ((orphan (created-slug
                   (ext:invoke-tool protocol :task_create
                                    (list :name "the unlinked orphan probe task") context))))
      (is (search orphan (query-text protocol context "(query \"orphans\")"))
          "the built-in orphans view finds the unlinked task")
      (run-query-write protocol context "(define! \"orphans\" (dormant))")
      (is (not (search orphan (query-text protocol context "(query \"orphans\")")))
          "the user view of the same name shadows the built-in")
      (run-query-write protocol context "(undefine! \"orphans\")")
      (is (search orphan (query-text protocol context "(query \"orphans\")"))
          "undefine! restores the built-in"))))

(test a-user-view-resolves-through-the-read-surface
  "A view defined on the write surface is resolvable by (query \"name\") on the
read surface — reading a view is a read."
  (with-cairn-protocol (context protocol)
    (let ((target (created-slug
                   (ext:invoke-tool protocol :task_create
                                    (list :name "the resolvable user view task") context))))
      (run-query-write protocol context "(define! \"mine\" (all))")
      (is (search target (query-text protocol context "(query \"mine\")"))
          "the user-defined view resolves by name under task_query")
      (is (search "mine" (tool-text (run-query protocol context "(query \"no-such-view\")")))
          "the unknown-view error enumerates user views alongside built-ins"))))

(test view-definitions-survive-a-rebuild
  "A view is a fold of view.* events, so rebuild reconstructs named_views exactly
and the projection stays a faithful fold of the log."
  (with-cairn-protocol (context protocol)
    (let ((target (created-slug
                   (ext:invoke-tool protocol :task_create
                                    (list :name "the rebuild persistence task") context))))
      (run-query-write protocol context "(define! \"persisted\" (all))")
      (let ((db (task-db protocol)))
        (cairn:rebuild db)
        (is (cairn:verify db) "the projection is a faithful fold after rebuild")
        (is (search target (query-text protocol context "(query \"persisted\")"))
            "the defined view resolves after a rebuild")))))

(test the-reserved-view-namespace-is-hidden-from-the-broad-sources
  "Defining a view auto-creates the @cairn namespace node, but it never appears
in (all)/(active)/(dormant); it remains addressable by (node ...)."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "the namespace visibility task") context)
    (run-query-write protocol context "(define! \"v\" (active))")
    (is (not (search "@cairn" (query-text protocol context "(-> (all) (:ids))")))
        "the reserved node is excluded from (all)")
    (is (not (search "@cairn" (query-text protocol context "(-> (active) (:ids))")))
        "the reserved node is excluded from (active)")
    (is (search "@cairn" (query-text protocol context "(-> (node \"@cairn\") (:ids))"))
        "the reserved node is still addressable by (node ...)")))

;;; Reflection: the language describes itself in its own carrier. The reflective
;;; sources return node-sets, so the same steps compose over the grammar — these
;;; tests probe the description with the algebra rather than asserting fixed text.

(test the-schema-source-is-a-composable-self-describing-grammar
  "(schema) renders the source/step/write vocabulary as a node-set the algebra
composes over: a shaper filter lists the terminal steps, and (schema) lists
itself among the sources."
  (with-cairn-protocol (context protocol)
    (let ((shapers (query-text protocol context
                     "(-> (schema) (:where (= :kind \"shaper\")) (:ids))")))
      (dolist (s '("select" "group-by" "ids" "count"))
        (is (search s shapers) (format nil "~A is listed as a shaper step" s))))
    (is (search "follow" (query-text protocol context
                  "(-> (schema) (:where (= :category \"step\")) (:ids))"))
        "follow is listed as a step")
    (is (search "schema" (query-text protocol context
                  "(-> (schema) (:where (= :category \"source\")) (:ids))"))
        "(schema) lists itself as a source")
    (is (search "define!" (query-text protocol context
                  "(-> (schema) (:where (= :category \"write\")) (:ids))"))
        "define! is listed as a write form")))

(test the-fields-source-lists-types-and-filters-by-them
  "(fields) is a node-set of the queryable fields; a predicate over :type selects
the numeric ones, and the count matches the registry."
  (with-cairn-protocol (context protocol)
    (let ((numeric (query-text protocol context
                     "(-> (fields) (:where (= :type \"number\")) (:ids))")))
      (dolist (f '("obs-count" "edge-count"))
        (is (search f numeric) (format nil "~A is a numeric field" f)))
      (is (not (search "description" numeric)) "a text field is not selected as numeric"))
    (is (search (format nil "~D" (length cairn::+field-types+))
                (query-text protocol context "(-> (fields) (:count))"))
        "the field count matches the registry")))

(test the-edges-source-classifies-each-edge-type
  "(edges) renders the edge vocabulary with each type's class; the structural
fibration includes both phase-of and forked-from, the latter being the type a
slug-blind traversal once missed."
  (with-cairn-protocol (context protocol)
    (let ((structural (query-text protocol context
                        "(-> (edges) (:where (= :class \"structural\")) (:ids))")))
      (is (search "phase-of" structural) "phase-of is structural")
      (is (search "forked-from" structural) "forked-from is structural"))
    (is (search "depends-on" (query-text protocol context
                  "(-> (edges) (:where (= :class \"lateral\")) (:ids))"))
        "depends-on is lateral")))

(test the-views-source-tags-builtin-and-user-views
  "(views) lists the shipped views, and after a define! the user view tagged by
origin — how reflection separates shipped vocabulary from model-defined."
  (with-cairn-protocol (context protocol)
    (is (search "plan-frontier" (query-text protocol context
                  "(-> (views) (:where (= :origin \"builtin\")) (:ids))"))
        "a shipped view is tagged builtin")
    (run-query-write protocol context "(define! \"mine\" (all))")
    (is (search "mine" (query-text protocol context
                  "(-> (views) (:where (= :origin \"user\")) (:ids))"))
        "a defined view is tagged user")))

(test reflection-sources-are-read-safe-and-total
  "Reflection runs on the read surface — it describes, never mutates — and stays
total: a task traversal over a grammar node is an honest empty set, not a crash."
  (with-cairn-protocol (context protocol)
    (is (not (ext:tool-result-error-p (run-query protocol context "(schema)")))
        "(schema) runs on the read-only surface")
    (is (not (ext:tool-result-error-p
              (run-query protocol context "(-> (fields) (:follow :phase-of))")))
        "a structural traversal over a grammar node does not error")
    (is (search "No matching tasks" (query-text protocol context
                  "(-> (fields) (:follow :phase-of))"))
        "and yields an honest empty set")))

;;; Mutation steps: writes as composable transformers. A mutation is a step
;;; gated at the tool surface, idempotent at the projection, and operand-safe —
;;; these probe each property through the real read and write tool boundaries.

(test a-mutation-step-is-refused-on-read-and-applied-on-write
  "(:set-status!) is an !-step: refused under task_query, applied under
task_query_write, where it drives the task to the new status and returns the set."
  (with-cairn-protocol (context protocol)
    (let ((task (created-slug
                 (ext:invoke-tool protocol :task_create
                                  (list :name "the status mutation probe task") context))))
      (is (ext:tool-result-error-p
           (run-query protocol context (node-query task "(:set-status! \"completed\")")))
          "a mutation step is refused on the read surface")
      (let ((result (run-query-write protocol context
                      (node-query task "(:set-status! \"completed\")"))))
        (is (not (ext:tool-result-error-p result)) "accepted on the write surface")
        (is (search task (tool-text result)) "and returns the mutated set"))
      (is (search task (query-text protocol context "(-> (dormant) (:ids))"))
          "the task is now dormant")
      (is (not (search task (query-text protocol context "(-> (active) (:ids))")))
          "and no longer active"))))

(test a-mutation-step-composes-and-converges-on-re-run
  "A mutation returns its node-set, so (:count) reports how many it touched, and
re-running converges on the same state rather than diverging."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create (list :name "first convergence task") context)
    (ext:invoke-tool protocol :task_create (list :name "second convergence task") context)
    (is (search "2" (query-write-text protocol context
                      "(-> (active) (:set-status! \"completed\") (:count))"))
        "the mutation touched both active tasks")
    (is (search "0" (query-write-text protocol context
                      "(-> (active) (:set-status! \"completed\") (:count))"))
        "re-running over the now-empty active set touches nothing")
    (is (search "2" (query-text protocol context "(-> (dormant) (:count))"))
        "both tasks remain completed — convergent, not divergent")))

(test set-metadata-step-writes-a-field-and-refuses-reserved-keys
  "(:set!) writes a metadata field on each task, visible after (:enrich), and
refuses :status, which has its own step."
  (with-cairn-protocol (context protocol)
    (let ((task (created-slug
                 (ext:invoke-tool protocol :task_create
                                  (list :name "the metadata mutation task") context))))
      (run-query-write protocol context
        (node-query task "(:set! :objective \"ship it\")"))
      (is (search "ship it" (query-text protocol context (node-query task "(:enrich)")))
          "the metadata field is set and surfaces under :enrich")
      (is (ext:tool-result-error-p
           (run-query-write protocol context
             (node-query task "(:set! :status \"completed\")")))
          "(:set! :status ...) is refused — status has its own step"))))

(test edge-mutation-steps-add-and-remove-a-lateral-edge
  "(:link!) adds an edge from each task to a target and (:unlink!) removes it; the
new edge is traversable by (:follow) in between."
  (with-cairn-protocol (context protocol)
    (let ((a (created-slug
              (ext:invoke-tool protocol :task_create
                               (list :name "edge mutation source task") context)))
          (b (created-slug
              (ext:invoke-tool protocol :task_create
                               (list :name "edge mutation target task") context))))
      (run-query-write protocol context
        (node-query a (format nil "(:link! :depends-on ~S)" b)))
      (is (search b (query-text protocol context
                      (node-query a "(:follow :depends-on)" "(:ids)")))
          "the linked edge is traversable")
      (run-query-write protocol context
        (node-query a (format nil "(:unlink! :depends-on ~S)" b)))
      (is (not (search b (query-text protocol context
                           (node-query a "(:follow :depends-on)" "(:ids)"))))
          "the severed edge is gone"))))

(test a-mutation-inside-an-operand-is-refused-on-the-write-surface
  "Sub-query operands are read-only even under task_query_write: a !-step inside
one is refused, so the surrounding write never applies it."
  (with-cairn-protocol (context protocol)
    (let ((task (created-slug
                 (ext:invoke-tool protocol :task_create
                                  (list :name "the operand safety task") context))))
      (is (ext:tool-result-error-p
           (run-query-write protocol context
             "(-> (active) (:union (-> (all) (:set-status! \"completed\"))))"))
          "a mutation inside a :union operand is refused on the write surface")
      (is (search task (query-text protocol context "(-> (active) (:ids))"))
          "and the task is untouched — still active"))))

(test a-mutation-over-synthesized-nodes-mints-no-phantom-task
  "A mutation touches only real tasks: run over a reflection node-set it records
nothing and mints no task, so the store stays clean."
  (with-cairn-protocol (context protocol)
    (run-query-write protocol context "(-> (fields) (:set-status! \"completed\"))")
    (is (search "No matching tasks" (query-text protocol context "(all)"))
        "no task was minted for a synthesized grammar node")))

(test the-schema-lists-mutation-steps-by-kind
  "The mutation steps self-describe: (schema) tags them kind=mutation, so the
write vocabulary is discoverable, not hardcoded in a description."
  (with-cairn-protocol (context protocol)
    (let ((muts (query-text protocol context
                  "(-> (schema) (:where (= :kind \"mutation\")) (:ids))")))
      (dolist (s '("set-status!" "set!" "link!" "unlink!"))
        (is (search s muts) (format nil "~A is listed as a mutation step" s))))))

(in-package #:kli/cairn)

;;; A small composable query language over the task projection. A query is an
;;; S-expression: a source form ((all), (node "sub"), (active), (dormant),
;;; (current), (query "name")) optionally threaded through pipeline steps with
;;; `->`. It is read with *read-eval* disabled and walked — never eval'd — then
;;; lowered onto SQL over tasks/edges/task_metadata plus a few in-memory folds.
;;; Every form yields a value or a structured cairn-query-error, never a
;;; backtrace and never a silent no-op. Every result is rendered to text before
;;; it leaves the runner, so nothing but a string crosses the tool boundary.
;;;
;;; Two typed registries drive the interpreter: sources (nullary producers of a
;;; node-set) and steps (transformers node-set->node-set, or shapers that
;;; terminate into a value). The edge/status/field vocabularies come from one
;;; place each so query, write, and (later) reflection never disagree.

;;; --- Conditions ---

(define-condition cairn-query-error (error)
  ((message :initarg :message :reader cairn-query-error-message)))

(define-condition cairn-query-parse-error (cairn-query-error) ())

;;; --- Per-call context, bound by the runner ---

(defvar *query-db* nil "The SQLite handle a query reads.")
(defvar *query-current* nil "The current task slug, for (current).")
(defvar *query-allow-mutation* nil
  "When NIL a `!`-suffixed form is refused. The read tool binds it NIL, so it is
provably non-mutating; the write tool binds it T. One dynamic is the whole
read/write gate.")

(defvar *query-context* nil
  "The tool context the write runner binds, so a `!`-form can append an event
through the durable boundary. NIL under the read surface.")

;;; --- Status registry: the active/dormant partition of the model enum ---

(defparameter +active-statuses+ '("open" "active" "blocked")
  "The live half of the status enum.")

(defparameter +dormant-statuses+ '("completed" "abandoned")
  "The settled half of the status enum.")

(eval-when (:load-toplevel :execute)
  (let ((partition (sort (copy-list (append +active-statuses+ +dormant-statuses+))
                         #'string<))
        (enum (sort (copy-list +cairn-statuses+) #'string<)))
    (unless (equal partition enum)
      (error "TQ status partition ~S does not cover the status enum ~S."
             partition enum))))

(defun %status-sql (statuses &optional (column "t.status"))
  "A `COLUMN IN ('a','b')` clause over the trusted STATUSES constants."
  (format nil "~A IN (~{'~A'~^,~})" column statuses))

;;; --- Field registry: declared type per field, for type-checked predicates ---

(defparameter +field-types+
  '((:slug . :text) (:status . :text) (:description . :text) (:depot . :text)
    (:parent . :text) (:display-name . :text)
    (:created-ts . :number) (:updated-ts . :number) (:status-ts . :number)
    (:obs-count . :number) (:edge-count . :number))
  "Known field -> value type. A field absent here is open metadata, read on
demand and treated as text.")

(defun %field-type (field)
  (or (cdr (assoc field +field-types+)) :text))

(defun %numeric-field-p (field)
  (eq (%field-type field) :number))

;;; --- Node hydration: a node is (slug . props), props a plain plist ---

(defparameter +node-select+
  "SELECT t.slug, t.depot, t.status, t.description, t.created_ts, t.updated_ts,
          t.status_ts, p.slug, dn.value
     FROM tasks t
     LEFT JOIN tasks p ON t.parent_task_id = p.id
     LEFT JOIN task_metadata dn ON dn.task_id = t.id AND dn.key = 'display-name'")

(defparameter +base-fields+
  '(:status :description :depot :created-ts :updated-ts :status-ts :parent
    :display-name)
  "Props every hydrated node carries without enrichment.")

(defun %local-field-p (field)
  "True when FIELD is already present (or is the slug itself) without enrichment."
  (or (eq field :slug) (member field +base-fields+)))

(defun %row->node (row)
  (destructuring-bind (slug depot status description created updated status-ts
                       parent display)
      row
    (cons slug (list :status status :description description :depot depot
                     :created-ts created :updated-ts updated :status-ts status-ts
                     :parent parent :display-name (or display slug)))))

(defun %hydrate (db where &rest params)
  "Hydrate the task rows matching WHERE (a clause without the WHERE keyword, or
NIL for all), ordered by slug for determinism."
  (let ((sql (concatenate 'string +node-select+
                          (if where (concatenate 'string " WHERE " where) "")
                          " ORDER BY t.slug")))
    (mapcar #'%row->node (apply #'sqlite:execute-to-list db sql params))))

(defun %slugs (nodes) (mapcar #'car nodes))

(defun %placeholders (n)
  (with-output-to-string (s)
    (dotimes (i n)
      (when (plusp i) (write-char #\, s))
      (write-char #\? s))))

(defun %hydrate-slugs (db slugs)
  (when slugs
    (apply #'%hydrate db
           (format nil "t.slug IN (~A)" (%placeholders (length slugs)))
           slugs)))

(defun %exact (slug)
  (%hydrate *query-db* "t.slug = ?" slug))

(defun %active-nodes (db)
  (%hydrate db (%status-sql +active-statuses+)))

(defparameter +visible-clause+ "t.slug NOT LIKE '@%'"
  "Excludes reserved-namespace nodes (an `@`-prefixed slug, e.g. the @cairn view
namespace) from the broad sources. Real task slugs are always date-prefixed, so
this drops nothing a user created; (node ...) and (current) still address them.")

(defun %and-clauses (&rest clauses)
  "Conjoin the non-NIL CLAUSES into one SQL WHERE body."
  (format nil "~{~A~^ AND ~}" (remove nil clauses)))

;;; --- Edge traversal: the one edge vocabulary comes from the model ---

(defun %known-edge-types ()
  (remove-duplicates (append +cairn-edge-types+ +structural-edge-types+)
                     :test #'string= :from-end t))

(defun %edge-class (edge)
  "Classify a query edge keyword against the model's edge registries. A
structural type traverses the parent FK (the fibration: phase-of and forked-from
are both folded there and indistinguishable in the store); a lateral type
traverses the edges table. An unrecognized type is a structured error, never a
silent empty traversal. Returns (values class type-name)."
  (let ((name (and (symbolp edge) (string-downcase (symbol-name edge)))))
    (cond
      ((null name)
       (error 'cairn-query-error
              :message "An edge step needs an edge type, e.g. (:follow :phase-of)."))
      ((structural-edge-type-p name) (values :structural name))
      ((member name +cairn-edge-types+ :test #'string=) (values :lateral name))
      (t (error 'cairn-query-error
                :message (format nil "Unknown edge type ~A; expected one of ~{~A~^, ~}."
                                 name (%known-edge-types)))))))

(defun %target-slugs (db nodes edge dir)
  "DISTINCT slugs reachable from NODES along EDGE in DIR (:follow or :back). The
edge type is validated first, so an unknown edge errors even on an empty input —
the edge is a property of the query, not of the data."
  (multiple-value-bind (class type) (%edge-class edge)
    (let ((slugs (%slugs nodes)))
      (when slugs
        (let ((ph (%placeholders (length slugs))))
          (flet ((run (sql &rest head)
                   (mapcar #'first
                           (apply #'sqlite:execute-to-list db sql
                                  (append head slugs)))))
            (ecase class
              (:structural
               (if (eq dir :follow)
                   (run (format nil "SELECT DISTINCT c.slug FROM tasks c
                                       JOIN tasks p ON c.parent_task_id = p.id
                                      WHERE p.slug IN (~A)" ph))
                   (run (format nil "SELECT DISTINCT p.slug FROM tasks c
                                       JOIN tasks p ON c.parent_task_id = p.id
                                      WHERE c.slug IN (~A)" ph))))
              (:lateral
               (if (eq dir :follow)
                   (run (format nil "SELECT DISTINCT d.slug FROM edges e
                                       JOIN tasks s ON e.src_id = s.id
                                       JOIN tasks d ON e.dst_id = d.id
                                      WHERE e.type = ? AND s.slug IN (~A)" ph)
                        type)
                   (run (format nil "SELECT DISTINCT s.slug FROM edges e
                                       JOIN tasks s ON e.src_id = s.id
                                       JOIN tasks d ON e.dst_id = d.id
                                      WHERE e.type = ? AND d.slug IN (~A)" ph)
                        type))))))))))

(defun %follow (db nodes edge)
  (%hydrate-slugs db (%target-slugs db nodes edge :follow)))

(defun %back (db nodes edge)
  (%hydrate-slugs db (%target-slugs db nodes edge :back)))

;;; --- Enrichment: counts and promoted metadata ---

(defun %enrich-node (db node)
  (let* ((slug (car node))
         (id (%task-id db slug)))
    (if (null id)
        node
        (let ((props (copy-list (cdr node))))
          (setf (getf props :obs-count)
                (sqlite:execute-single db
                  "SELECT COUNT(*) FROM observations WHERE task_id = ?" id))
          (setf (getf props :edge-count)
                (+ (sqlite:execute-single db
                     "SELECT COUNT(*) FROM edges WHERE src_id = ? OR dst_id = ?" id id)
                   (sqlite:execute-single db
                     "SELECT COUNT(*) FROM tasks WHERE parent_task_id = ?" id)
                   (if (getf props :parent) 1 0)))
          (dolist (row (sqlite:execute-to-list db
                         "SELECT key, value FROM task_metadata WHERE task_id = ?" id))
            (destructuring-bind (key value) row
              (setf (getf props (intern (string-upcase key) :keyword)) value)))
          (cons slug props)))))

(defun %enrich (db nodes)
  (mapcar (lambda (n) (%enrich-node db n)) nodes))

(defun %enriched-p (nodes)
  (and nodes (getf (cdr (first nodes)) :obs-count) t))

(defun %maybe-enrich (db nodes fields)
  "Enrich NODES only when a referenced FIELD is not already local and the set is
not yet enriched."
  (if (and nodes
           (some (lambda (f) (not (%local-field-p f))) fields)
           (not (%enriched-p nodes)))
      (%enrich db nodes)
      nodes))

;;; --- Predicates ---

(defun sym= (sym name)
  (and (symbolp sym) (string-equal (symbol-name sym) name)))

(defun %pred-head (form)
  "The downcased head name of a predicate/source/step FORM, or NIL."
  (and (consp form) (symbolp (car form)) (string-downcase (symbol-name (car form)))))

(defun %extract-fields (pred)
  "The field keywords a predicate references, for auto-enrichment."
  (let ((head (%pred-head pred)))
    (cond
      ((null head) nil)
      ((member head '("=" "has" "matches" ">" "<" ">=") :test #'string=)
       (let ((f (second pred))) (when (keywordp f) (list f))))
      ((member head '("and" "or") :test #'string=)
       (mapcan #'%extract-fields (cdr pred)))
      ((string= head "not") (%extract-fields (second pred)))
      (t nil))))

(defun %field-value (field slug props)
  "FIELD's value on a node; :slug reads the node's own slug, the rest its props."
  (if (eq field :slug) slug (getf props field)))

(defun %require-field (field op)
  (unless (keywordp field)
    (error 'cairn-query-error
           :message (format nil "~A needs a field keyword like :status, got ~S." op field))))

(defun %compile-traversal (trav op-label)
  "Compile a relative traversal — (:follow EDGE) or (:back EDGE) — into a function
from a focus node to the node-set one hop away. The edge is validated eagerly, so
an ill-typed quantifier errors even over an empty input set: the edge is a
property of the query, not of the data."
  (unless (and (consp trav) (member (car trav) '(:follow :back)))
    (error 'cairn-query-error
           :message (format nil "~A needs a traversal (:follow EDGE) or (:back EDGE), got ~S."
                            op-label trav)))
  (let ((dir (car trav)) (edge (second trav)))
    (%edge-class edge)
    (lambda (node)
      (if (eq dir :follow)
          (%follow *query-db* (list node) edge)
          (%back *query-db* (list node) edge)))))

(defun %count-expr-p (expr)
  "True when EXPR is a (count TRAV) field-expression."
  (and (consp expr) (equal (%pred-head expr) "count")))

(defun %compile-count (expr)
  "Compile (count TRAV) into a focus-node -> non-negative integer."
  (let ((traverse (%compile-traversal (second expr) "(count TRAV)")))
    (lambda (slug props) (length (funcall traverse (cons slug props))))))

(defun %compile-value (expr op-label)
  "Compile the left side of an (= LHS v) test: a field keyword read off the node,
or (count TRAV), the cardinality of a relative traversal."
  (cond
    ((keywordp expr) (lambda (slug props) (%field-value expr slug props)))
    ((%count-expr-p expr) (%compile-count expr))
    (t (error 'cairn-query-error
              :message (format nil "~A needs a field keyword or (count TRAV), got ~S."
                               op-label expr)))))

(defun %numeric-lhs (lhs op-label)
  "Compile the left side of a numeric comparison to a focus-node -> real getter. A
field keyword must be declared numeric; (count TRAV) is numeric by construction."
  (cond
    ((keywordp lhs)
     (unless (%numeric-field-p lhs)
       (error 'cairn-query-error
              :message (format nil "~A needs a numeric field; ~(~S~) is textual." op-label lhs)))
     (lambda (slug props) (declare (ignore slug)) (getf props lhs)))
    ((%count-expr-p lhs) (%compile-count lhs))
    (t (error 'cairn-query-error
              :message (format nil "~A needs a numeric field or (count TRAV), got ~S."
                               op-label lhs)))))

(defun %numeric-pred (op-fn op-label lhs value)
  "Compile a numeric comparison. The left side is a numeric field or (count TRAV)
and the operand a real number, else the query is ill-typed and errors — a smart
model must be able to tell a type error from an empty result."
  (let ((getter (%numeric-lhs lhs op-label)))
    (unless (realp value)
      (error 'cairn-query-error
             :message (format nil "~A needs a real-number operand, got ~S." op-label value)))
    (lambda (slug props)
      (let ((v (funcall getter slug props)))
        (and (realp v) (funcall op-fn v value))))))

(defun interpret-where (pred)
  "Compile a predicate form into a function of (slug props)."
  (unless (consp pred)
    (error 'cairn-query-error
           :message (format nil "A predicate is a form like (= :status \"active\"), got ~S." pred)))
  (let ((head (%pred-head pred)))
    (cond
      ((string= head "=")
       (let ((getter (%compile-value (second pred) "="))
             (val (third pred)))
         (lambda (slug props) (equal (funcall getter slug props) val))))
      ((string= head "has")
       (let ((f (second pred)))
         (%require-field f "has")
         (lambda (slug props) (and (%field-value f slug props) t))))
      ((string= head "matches")
       (let ((f (second pred)) (sub (third pred)))
         (%require-field f "matches")
         (unless (stringp sub)
           (error 'cairn-query-error
                  :message "(matches FIELD \"substr\") needs a string substring."))
         (lambda (slug props)
           (let ((v (%field-value f slug props)))
             (and (stringp v) (search sub v :test #'char-equal) t)))))
      ((string= head ">") (%numeric-pred #'> ">" (second pred) (third pred)))
      ((string= head "<") (%numeric-pred #'< "<" (second pred) (third pred)))
      ((string= head ">=") (%numeric-pred #'>= ">=" (second pred) (third pred)))
      ((string= head "and")
       (let ((ps (mapcar #'interpret-where (cdr pred))))
         (lambda (slug props) (every (lambda (p) (funcall p slug props)) ps))))
      ((string= head "or")
       (let ((ps (mapcar #'interpret-where (cdr pred))))
         (lambda (slug props) (some (lambda (p) (funcall p slug props)) ps))))
      ((string= head "not")
       (let ((p (interpret-where (second pred))))
         (lambda (slug props) (not (funcall p slug props)))))
      ((member head '("all" "any" "none") :test #'string=)
       (unless (= (length pred) 3)
         (error 'cairn-query-error
                :message (format nil "(~A TRAV PRED) needs a traversal and a predicate, got ~S." head pred)))
       (let* ((traverse (%compile-traversal (second pred) (format nil "(~A ...)" head)))
              (inner (interpret-where (third pred)))
              (fields (%extract-fields (third pred)))
              (test (cond ((string= head "all") #'every)
                          ((string= head "any") #'some)
                          (t #'notany))))
         (lambda (slug props)
           (let ((nodes (%maybe-enrich *query-db*
                                       (funcall traverse (cons slug props))
                                       fields)))
             (funcall test (lambda (n) (funcall inner (car n) (cdr n))) nodes)))))
      (t (error 'cairn-query-error
                :message (format nil "Unknown predicate: ~S" pred))))))

;;; --- Projection / grouping carriers (internal; rendered in the runner) ---

(defstruct (q-projection (:conc-name qp-)) nodes fields)
(defstruct (q-group (:conc-name qg-)) field groups)

(defun %sort-by (nodes field)
  "Sort NODES by FIELD, descending. Numeric when the field holds numbers."
  (when nodes
    (let ((numeric (loop for n in nodes
                         for v = (getf (cdr n) field)
                         when v return (realp v))))
      (sort (copy-list nodes)
            (if numeric #'> #'string>)
            :key (lambda (n)
                   (let ((v (getf (cdr n) field)))
                     (if numeric (or v 0)
                         (if (stringp v) v (princ-to-string (or v ""))))))))))

(defun %group-by (nodes field)
  (let ((table (make-hash-table :test 'equal)))
    (dolist (n nodes)
      (push n (gethash (or (getf (cdr n) field) :none) table)))
    (let ((groups nil))
      (maphash (lambda (k v) (push (cons k (nreverse v)) groups)) table)
      (make-q-group
       :field field
       :groups (sort groups
                     (lambda (a b)
                       (let ((ca (length (cdr a))) (cb (length (cdr b))))
                         (if (= ca cb)
                             (string< (princ-to-string (car a))
                                      (princ-to-string (car b)))
                             (> ca cb)))))))))

(defun %take (nodes n)
  (subseq nodes 0 (min n (length nodes))))

;;; --- Named queries: views are data, not tool surface ---

(defun %current-node ()
  (unless *query-current*
    (error 'cairn-query-error
           :message "This query needs a current task; select one first."))
  (or (%exact *query-current*)
      (error 'cairn-query-error
             :message (format nil "The current task ~A is not in the store."
                              *query-current*))))

(defparameter +named-queries+
  '(("active-roots"  . "(-> (active) (:where (not (has :parent))))")
    ("orphans"       . "(-> (all) (:where (= :edge-count 0)))")
    ("leaf-tasks"    . "(-> (active) (:where (= (count (:follow :phase-of)) 0)))")
    ("stale-phases"  . "(-> (active) (:where (any (:back :phase-of) (or (= :status \"completed\") (= :status \"abandoned\")))))")
    ("plan"          . "(-> (current) (:follow :phase-of) (:or-else (-> (current) (:back :phase-of) (:follow :phase-of))) (:enrich))")
    ("plan-frontier" . "(-> (query \"plan\") (:where (and (not (or (= :status \"completed\") (= :status \"abandoned\"))) (all (:follow :depends-on) (or (= :status \"completed\") (= :status \"abandoned\"))))))")
    ("frontier"      . "(query \"plan-frontier\")")
    ("recent"        . "(-> (active) (:sort :updated-ts) (:take 20))")
    ("busy"          . "(-> (active) (:sort :obs-count) (:take 20))")
    ("hub-tasks"     . "(-> (active) (:sort :edge-count) (:take 20))")
    ("knowledge"     . "(-> (current) (:closure :phase-of :depends-on :related) (:enrich))"))
  "Built-in view name -> its TQ source text: the language's shipped vocabulary,
expressed in itself. A user-defined view of the same name shadows the built-in.")

(defvar *resolving-views* nil
  "The stack of view names being resolved, so a self-referential definition is a
structured error rather than an unbounded loop.")

(defun %user-view-text (name)
  "The TQ source of a user-defined view NAME from named_views, or NIL."
  (and *query-db*
       (sqlite:execute-single *query-db*
         "SELECT query FROM named_views WHERE name = ?" name)))

(defun %user-view-names ()
  "Every user-defined view name in the store."
  (and *query-db*
       (mapcar #'first
               (sqlite:execute-to-list *query-db*
                 "SELECT name FROM named_views ORDER BY name"))))

(defun %view-names ()
  "Every resolvable view name, for the unknown-view error."
  (remove-duplicates (append (%user-view-names) (mapcar #'car +named-queries+))
                     :test #'equal :from-end t))

(defun %view-text (name)
  "The TQ source for view NAME. A user-defined view shadows the in-code built-in
of the same name; NIL when no view carries the name."
  (or (%user-view-text name)
      (cdr (assoc name +named-queries+ :test #'equal))))

(defun run-named-query (name)
  "Resolve a named view to its node-set by interpreting its TQ source. A view
defined in terms of itself errors rather than looping."
  (when (member name *resolving-views* :test #'equal)
    (error 'cairn-query-error
           :message (format nil "View ~A is defined in terms of itself." name)))
  (let ((text (%view-text name)))
    (unless text
      (error 'cairn-query-error
             :message (format nil "Unknown named query ~A. Available: ~{~A~^, ~}."
                              name (%view-names))))
    (let ((*resolving-views* (cons name *resolving-views*)))
      (interpret-query (safe-read-query text)))))

;;; --- Pipeline steps: the typed step table ---

(defun %mutation-form-p (form)
  "True when FORM names a mutation: a (sym ...) whose head ends in #\\! — a write
step like (:complete!) or a write source like (define! ...)."
  (and (consp form)
       (symbolp (car form))
       (let ((name (symbol-name (car form))))
         (and (plusp (length name))
              (char= (char name (1- (length name))) #\!)))))

(defun %refuse-mutation ()
  "Signal the one read/write-gate error: a mutation form under the read surface."
  (error 'cairn-query-error
         :message "Mutations need the task_query_write surface; task_query is read-only."))

(defun %node-set-p (x)
  "A node-set is NIL or a list of (slug . props) conses; never a terminal value."
  (or (null x)
      (and (consp x) (consp (first x)) (stringp (car (first x))))))

;;; --- Set algebra: sub-queries combined as node-sets ---

(defun %eval-node-set (form what)
  "Evaluate FORM read-only and require it yield a node-set. WHAT names the role
in the error. Read-only means a `!`-form inside is refused regardless of the
write surface — you combine and define over selections, you do not mutate inside
them."
  (let ((*query-allow-mutation* nil))
    (let ((result (interpret-expr form)))
      (unless (%node-set-p result)
        (error 'cairn-query-error
               :message (format nil "~A must yield a set of tasks, not a final value." what)))
      result)))

(defun %eval-operand (form)
  "Evaluate a set-operation operand to a node-set, read-only."
  (%eval-node-set form "A set-operation operand"))

(defun %slug-set (nodes)
  (let ((h (make-hash-table :test 'equal)))
    (dolist (n nodes h) (setf (gethash (car n) h) t))))

(defun %by-slug (nodes)
  "NODES sorted by slug, the deterministic order for set-operation output."
  (sort (copy-list nodes) #'string< :key #'car))

(defun %union (a b)
  "A ∪ B by slug identity, keeping A's hydration where the two overlap."
  (let ((seen (%slug-set a)))
    (%by-slug (append a (remove-if (lambda (n) (gethash (car n) seen)) b)))))

(defun %intersect (a b)
  (let ((other (%slug-set b)))
    (%by-slug (remove-if-not (lambda (n) (gethash (car n) other)) a))))

(defun %minus (a b)
  (let ((other (%slug-set b)))
    (%by-slug (remove-if (lambda (n) (gethash (car n) other)) a))))

(defun %operand-of (args op)
  (unless (= (length args) 1)
    (error 'cairn-query-error
           :message (format nil "~A needs exactly one sub-query operand." op)))
  (%eval-operand (first args)))

(defun %closure-step (db nodes edges)
  "Forward transitive reachability from NODES over EDGES (a list of edge
keywords), cycle-safe and bounded to depth 5. The starting NODES are excluded
unless a cycle leads back to one. Each edge is validated eagerly, so an unknown
edge errors even over an empty input — the edge is a property of the query."
  (unless edges
    (error 'cairn-query-error
           :message "(:closure EDGE...) needs at least one edge type."))
  (dolist (edge edges) (%edge-class edge))
  (let ((seen (make-hash-table :test 'equal))
        (result nil))
    (dolist (n nodes) (setf (gethash (car n) seen) t))
    (labels ((walk (node depth)
               (when (<= depth 5)
                 (dolist (edge edges)
                   (dolist (nb (%follow db (list node) edge))
                     (unless (gethash (car nb) seen)
                       (setf (gethash (car nb) seen) t)
                       (push nb result)
                       (walk nb (1+ depth))))))))
      (dolist (n nodes) (walk n 0)))
    (nreverse result)))

;; A step is (KEYWORD . ARGS). Its descriptor tags whether it is a TRANSFORMER
;; (node-set -> node-set, composable) or a SHAPER (node-set -> a terminal value,
;; a functor out of the algebra). HANDLER takes (db input args). The kind tag is
;; the two-tier grammar — transformers compose, shapers terminate — made
;; explicit, and the seed the reflection surface will read.
(defstruct (tq-step (:conc-name tqs-))
  (key nil :read-only t)
  (kind nil :read-only t)
  (handler nil :read-only t)
  (doc nil :read-only t))

(defun %field-arg (args op)
  (let ((f (first args)))
    (unless (keywordp f)
      (error 'cairn-query-error
             :message (format nil "~A needs a field keyword, e.g. (~A :status)." op op)))
    f))

;;; --- Mutation steps: writes as composable transformers ---
;;
;; A mutation is a transformer (node-set -> node-set) that records a per-node
;; event through the durable boundary and returns its input, so it composes like
;; any step — (:count) after it reports how many tasks it touched. The events are
;; append-only and their projection effects converge (status, metadata, and edges
;; settle to the written value), so re-running is safe. Only real tasks are
;; touched: a synthesized node carries no task id and is passed over, never
;; minting a phantom. interpret-step gates on the :mutation kind, not on registry
;; membership, so a write can never slip through the read surface.

(defun %patch-prop (node key value)
  "NODE with KEY set to VALUE in a fresh prop list, so a mutated set renders the
value a re-read would show."
  (let ((props (copy-list (cdr node))))
    (setf (getf props key) value)
    (cons (car node) props)))

(defun %mutate-nodes (input record patch)
  "Record a per-node event for each real task in INPUT and return INPUT with
PATCH applied to the touched nodes. A node with no task id is left untouched."
  (unless *query-context*
    (error 'cairn-query-error
           :message "A mutation needs the task_query_write surface."))
  (mapcar (lambda (node)
            (if (%task-id *query-db* (car node))
                (progn (funcall record (car node)) (funcall patch node))
                node))
          input))

(defun %set-status-step (input args)
  (let ((status (first args)))
    (unless (and (stringp status) (status-valid-p status))
      (error 'cairn-query-error
             :message (format nil "(:set-status! STATUS) needs one of ~{~A~^, ~}."
                              +cairn-statuses+)))
    (%mutate-nodes input
                   (lambda (slug)
                     (%record *query-context* slug "task.update-status"
                              (list :status status)))
                   (lambda (node) (%patch-prop node :status status)))))

(defun %set-meta-step (input args)
  (let ((key (first args)) (value (second args)))
    (unless (keywordp key)
      (error 'cairn-query-error
             :message "(:set! :key \"value\") needs a field keyword."))
    (when (member key '(:slug :status))
      (error 'cairn-query-error
             :message "(:set! ...) will not set :slug or :status; use (:set-status! STATUS) for status."))
    (let ((name (string-downcase (symbol-name key)))
          (val (if (stringp value) value (princ-to-string (or value "")))))
      (%mutate-nodes input
                     (lambda (slug)
                       (%record *query-context* slug "task.set-metadata"
                                (list :key name :value val)))
                     (lambda (node) (%patch-prop node key val))))))

(defun %mutation-edge-type (arg)
  "ARG as a lateral edge-type name, mirroring the write tools' enum. A plain
error here would escape the runner, so an ill-typed edge is a cairn-query-error."
  (let ((et (and (symbolp arg) (string-downcase (symbol-name arg)))))
    (cond
      ((null et)
       (error 'cairn-query-error
              :message "An edge mutation needs an edge type, e.g. (:link! :depends-on \"slug\")."))
      ((member et +cairn-edge-types+ :test #'string=) et)
      (t (error 'cairn-query-error
                :message (format nil "Unknown edge type ~A; expected one of ~{~A~^, ~}."
                                 et +cairn-edge-types+))))))

(defun %edge-step (input args type)
  "Record TYPE (task.link or task.sever) from each task to a constant target. A
node equal to the target is skipped — a task does not edge to itself."
  (let ((edge (%mutation-edge-type (first args)))
        (target (%bare-slug (second args))))
    (unless (and (stringp target) (plusp (length target)))
      (error 'cairn-query-error :message "An edge mutation needs a target slug."))
    (%mutate-nodes input
                   (lambda (slug)
                     (unless (string= slug target)
                       (%record *query-context* slug type
                                (list :target-id target :edge-type edge))))
                   #'identity)))

(defparameter +tq-steps+
  (list
   (make-tq-step :key :follow :kind :transformer
                 :handler (lambda (db input args) (%follow db input (first args)))
                 :doc "(:follow EDGE) — the tasks one EDGE hop forward.")
   (make-tq-step :key :back :kind :transformer
                 :handler (lambda (db input args) (%back db input (first args)))
                 :doc "(:back EDGE) — the tasks one EDGE hop backward.")
   (make-tq-step :key :where :kind :transformer
                 :handler (lambda (db input args)
                            (let ((fn (interpret-where (first args)))
                                  (nodes (%maybe-enrich db input (%extract-fields (first args)))))
                              (remove-if-not (lambda (n) (funcall fn (car n) (cdr n))) nodes)))
                 :doc "(:where PRED) — the tasks satisfying PRED.")
   (make-tq-step :key :sort :kind :transformer
                 :handler (lambda (db input args)
                            (let ((field (%field-arg args ":sort")))
                              (%sort-by (%maybe-enrich db input (list field)) field)))
                 :doc "(:sort FIELD) — descending by FIELD.")
   (make-tq-step :key :take :kind :transformer
                 :handler (lambda (db input args)
                            (declare (ignore db))
                            (let ((n (first args)))
                              (unless (integerp n)
                                (error 'cairn-query-error :message "(:take N) needs an integer count."))
                              (%take input (max 0 n))))
                 :doc "(:take N) — the first N tasks.")
   (make-tq-step :key :enrich :kind :transformer
                 :handler (lambda (db input args) (declare (ignore args)) (%enrich db input))
                 :doc "(:enrich) — add counts and promoted metadata.")
   (make-tq-step :key :union :kind :transformer
                 :handler (lambda (db input args) (declare (ignore db))
                            (%union input (%operand-of args ":union")))
                 :doc "(:union Q) — tasks in the pipeline or in sub-query Q.")
   (make-tq-step :key :intersect :kind :transformer
                 :handler (lambda (db input args) (declare (ignore db))
                            (%intersect input (%operand-of args ":intersect")))
                 :doc "(:intersect Q) — tasks in both the pipeline and sub-query Q.")
   (make-tq-step :key :minus :kind :transformer
                 :handler (lambda (db input args) (declare (ignore db))
                            (%minus input (%operand-of args ":minus")))
                 :doc "(:minus Q) — pipeline tasks not in sub-query Q.")
   (make-tq-step :key :or-else :kind :transformer
                 :handler (lambda (db input args) (declare (ignore db))
                            (if input input (%operand-of args ":or-else")))
                 :doc "(:or-else Q) — the pipeline if it holds any task, else sub-query Q.")
   (make-tq-step :key :closure :kind :transformer
                 :handler (lambda (db input args) (%closure-step db input args))
                 :doc "(:closure EDGE...) — the forward transitive closure over the EDGEs, cycle-safe.")
   (make-tq-step :key :select :kind :shaper
                 :handler (lambda (db input args)
                            (declare (ignore db))
                            (unless args
                              (error 'cairn-query-error :message "(:select FIELD...) needs at least one field."))
                            (make-q-projection :nodes input :fields args))
                 :doc "(:select FIELD...) — project the named fields.")
   (make-tq-step :key :group-by :kind :shaper
                 :handler (lambda (db input args)
                            (let ((field (%field-arg args ":group-by")))
                              (%group-by (%maybe-enrich db input (list field)) field)))
                 :doc "(:group-by FIELD) — bucket by FIELD value.")
   (make-tq-step :key :ids :kind :shaper
                 :handler (lambda (db input args) (declare (ignore db args)) (%slugs input))
                 :doc "(:ids) — the slugs only.")
   (make-tq-step :key :count :kind :shaper
                 :handler (lambda (db input args) (declare (ignore db args)) (length input))
                 :doc "(:count) — the cardinality.")
   (make-tq-step :key :set-status! :kind :mutation
                 :handler (lambda (db input args) (declare (ignore db)) (%set-status-step input args))
                 :doc "(:set-status! STATUS) — set each task's status; converges on re-run.")
   (make-tq-step :key :set! :kind :mutation
                 :handler (lambda (db input args) (declare (ignore db)) (%set-meta-step input args))
                 :doc "(:set! :key \"value\") — set a metadata field on each task.")
   (make-tq-step :key :link! :kind :mutation
                 :handler (lambda (db input args) (declare (ignore db)) (%edge-step input args "task.link"))
                 :doc "(:link! :edge \"target\") — add an edge from each task to target.")
   (make-tq-step :key :unlink! :kind :mutation
                 :handler (lambda (db input args) (declare (ignore db)) (%edge-step input args "task.sever"))
                 :doc "(:unlink! :edge \"target\") — remove the edge from each task to target."))
  "The step vocabulary: transformers compose, shapers terminate, mutations write.")

(defun %find-step (key) (find key +tq-steps+ :key #'tqs-key))

(defun interpret-step (result step)
  (unless (%node-set-p result)
    (error 'cairn-query-error
           :message "This step expects a set of tasks, but the previous step produced a final value."))
  (unless (consp step)
    (error 'cairn-query-error
           :message (format nil "A step is a form like (:follow :phase-of), got ~S." step)))
  (let ((desc (and (keywordp (car step)) (%find-step (car step)))))
    (cond
      (desc
       (when (and (eq (tqs-kind desc) :mutation) (not *query-allow-mutation*))
         (%refuse-mutation))
       (funcall (tqs-handler desc) *query-db* result (cdr step)))
      ((and (%mutation-form-p step) (not *query-allow-mutation*))
       (%refuse-mutation))
      (t (error 'cairn-query-error
                :message (format nil "Unknown step: ~S" step))))))

;;; --- Sources: the typed source table ---

(defstruct (tq-source (:conc-name tqr-))
  (name nil :read-only t)
  (handler nil :read-only t)
  (doc nil :read-only t))

;;; --- Reflection: the language describes itself in its own carrier ---
;;
;; The vocabularies — fields, edges, views, the grammar — are synthesized into
;; node-sets `(name . props)`, the same carrier task queries already produce, so
;; every step composes over them for free: (-> (fields) (:where (= :type
;; "number")) (:ids)) reads the schema with the algebra. Each list is generated
;; from the registry the interpreter dispatches on, so the description cannot
;; drift from behavior. The slugs are bare names (never date-prefixed), so they
;; never collide with a task and enrichment over them is an honest no-op.

(defun %sort-nodes (nodes)
  "Order a synthesized node-set by slug, matching %hydrate's determinism."
  (sort (copy-list nodes) #'string< :key #'car))

(defun %field-nodes ()
  "The declared field vocabulary: each field a node carrying its :type."
  (%sort-nodes
   (mapcar (lambda (ft)
             (cons (string-downcase (symbol-name (car ft)))
                   (list :type (string-downcase (symbol-name (cdr ft))))))
           +field-types+)))

(defun %edge-nodes ()
  "The edge vocabulary, each type carrying the :class %edge-class assigns it: a
structural type traverses the fibration, a lateral type the edges table."
  (%sort-nodes
   (mapcar (lambda (name)
             (cons name (list :class (if (structural-edge-type-p name)
                                         "structural" "lateral"))))
           (%known-edge-types))))

(defun %view-nodes ()
  "The named-view vocabulary: every user view (:origin user) and every built-in
not shadowed by one (:origin builtin), each carrying its TQ :source text."
  (let ((user (%user-view-names)))
    (%sort-nodes
     (append
      (mapcar (lambda (name)
                (cons name (list :origin "user" :source (%user-view-text name))))
              user)
      (loop for (name . text) in +named-queries+
            unless (member name user :test #'equal)
              collect (cons name (list :origin "builtin" :source text)))))))

(defparameter +tq-sources+
  (list
   (make-tq-source :name "all"
                   :handler (lambda (args) (declare (ignore args))
                              (%hydrate *query-db* +visible-clause+))
                   :doc "(all) — every task.")
   (make-tq-source :name "active"
                   :handler (lambda (args) (declare (ignore args))
                              (%hydrate *query-db*
                                        (%and-clauses (%status-sql +active-statuses+)
                                                      +visible-clause+)))
                   :doc "(active) — open, active, or blocked tasks.")
   (make-tq-source :name "dormant"
                   :handler (lambda (args) (declare (ignore args))
                              (%hydrate *query-db*
                                        (%and-clauses (%status-sql +dormant-statuses+)
                                                      +visible-clause+)))
                   :doc "(dormant) — completed or abandoned tasks.")
   (make-tq-source :name "current"
                   :handler (lambda (args) (declare (ignore args)) (%current-node))
                   :doc "(current) — the current task.")
   (make-tq-source :name "node"
                   :handler (lambda (args)
                              (let ((p (first args)))
                                (when (or (null p) (and (stringp p) (zerop (length p))))
                                  (error 'cairn-query-error :message "(node \"substr\") needs a non-empty pattern."))
                                (%hydrate *query-db* "instr(lower(t.slug), ?) > 0" (string-downcase p))))
                   :doc "(node \"substr\") — tasks whose slug contains the substring.")
   (make-tq-source :name "query"
                   :handler (lambda (args) (run-named-query (first args)))
                   :doc "(query \"name\") — a named view.")
   (make-tq-source :name "schema"
                   :handler (lambda (args) (declare (ignore args)) (%schema-nodes))
                   :doc "(schema) — the source/step/write grammar as a queryable node-set.")
   (make-tq-source :name "views"
                   :handler (lambda (args) (declare (ignore args)) (%view-nodes))
                   :doc "(views) — the named views, built-in and user, as a queryable node-set.")
   (make-tq-source :name "fields"
                   :handler (lambda (args) (declare (ignore args)) (%field-nodes))
                   :doc "(fields) — the queryable fields and their value types.")
   (make-tq-source :name "edges"
                   :handler (lambda (args) (declare (ignore args)) (%edge-nodes))
                   :doc "(edges) — the edge vocabulary and each type's class."))
  "The source vocabulary: nullary producers of a node-set.")

(defun %find-source (name) (find name +tq-sources+ :key #'tqr-name :test #'string=))

(defun %pq-source-p (sym)
  (and (symbolp sym)
       (member (symbol-name sym) '("ACTIVATE" "PROVEN" "WARNINGS" "PATTERN")
               :test #'string-equal)))

;;; --- Write forms: view vocabulary defined as events ---

(defparameter +view-namespace+ "@cairn"
  "The reserved node that owns view.define/view.undefine events. A definition is
global, yet every cairn event belongs to a node; @cairn is the honest subject —
the global namespace — so view events ride the one event spine unchanged and
rebuild reconstructs the vocabulary from the log like any other projection.")

(defun %serialize-query (form)
  "FORM printed back to TQ source text, round-trippable by safe-read-query: the
:kli/cairn package and downcase make symbols print as they were read."
  (let ((*package* (find-package :kli/cairn))
        (*print-case* :downcase)
        (*print-readably* nil))
    (prin1-to-string form)))

(defun %record-view (type payload)
  "Append a view.* event under the reserved namespace through the durable
boundary. Needs the write context the write runner binds."
  (unless *query-context*
    (error 'cairn-query-error
           :message "A view definition needs the task_query_write surface."))
  (%record *query-context* +view-namespace+ type payload))

(defun %define-view (form)
  "(define! \"name\" Q) — validate Q read-only, record its text as a view.define
event, and return Q's node-set so define! is interchangeable with Q."
  (unless (= (length form) 3)
    (error 'cairn-query-error
           :message "(define! \"name\" Q) takes a view name and a query."))
  (let ((name (second form))
        (query (third form)))
    (unless (and (stringp name) (plusp (length name)))
      (error 'cairn-query-error
             :message "(define! \"name\" Q) needs a non-empty string view name."))
    (let ((value (%eval-node-set query "A view definition")))
      (%record-view "view.define" (list :name name :query (%serialize-query query)))
      value)))

(defun %undefine-view (form)
  "(undefine! \"name\") — record a view.undefine event and return NIL."
  (unless (= (length form) 2)
    (error 'cairn-query-error
           :message "(undefine! \"name\") takes a view name."))
  (let ((name (second form)))
    (unless (and (stringp name) (plusp (length name)))
      (error 'cairn-query-error
             :message "(undefine! \"name\") needs a non-empty string view name."))
    (%record-view "view.undefine" (list :name name))
    nil))

(defstruct (tq-write-form (:conc-name tqw-))
  (name nil :read-only t)
  (handler nil :read-only t)
  (doc nil :read-only t))

(defparameter +tq-write-forms+
  (list
   (make-tq-write-form :name "define!" :handler #'%define-view
     :doc "(define! \"name\" Q) — record Q as a named view and return its tasks.")
   (make-tq-write-form :name "undefine!" :handler #'%undefine-view
     :doc "(undefine! \"name\") — remove a user view, restoring any built-in."))
  "The write-form vocabulary: `!`-suffixed source forms gated by the write
surface. The reflection grammar reads it so the write surface self-describes.")

(defun interpret-write-form (form)
  "Dispatch a `!`-suffixed source form, gated by the write surface. An unknown
write head is a structured error, not a silent miss."
  (unless *query-allow-mutation*
    (%refuse-mutation))
  (let ((wf (find (%pred-head form) +tq-write-forms+ :key #'tqw-name :test #'string=)))
    (if wf
        (funcall (tqw-handler wf) form)
        (error 'cairn-query-error
               :message (format nil "Unknown write form: ~S" form)))))

(defun %schema-nodes ()
  "The combinator grammar as a node-set: every source, step, and write form a
node tagged by :category (and steps by :kind), carrying its :doc. Generated from
the registries the interpreter dispatches on, so the grammar cannot drift from
behavior; (schema) lists itself and the other reflective sources."
  (%sort-nodes
   (append
    (mapcar (lambda (s)
              (cons (tqr-name s) (list :category "source" :doc (tqr-doc s))))
            +tq-sources+)
    (mapcar (lambda (s)
              (cons (string-downcase (symbol-name (tqs-key s)))
                    (list :category "step"
                          :kind (string-downcase (symbol-name (tqs-kind s)))
                          :doc (tqs-doc s))))
            +tq-steps+)
    (mapcar (lambda (w)
              (cons (tqw-name w) (list :category "write" :doc (tqw-doc w))))
            +tq-write-forms+))))

(defun interpret-expr (form)
  (cond
    ((atom form)
     (error 'cairn-query-error
            :message (format nil "A query is a source form like (all) or (node \"x\"), got ~S." form)))
    ((sym= (car form) "->") (interpret-pipeline (cdr form)))
    ((%mutation-form-p form) (interpret-write-form form))
    (t (let ((src (and (symbolp (car form)) (%find-source (%pred-head form)))))
         (cond
           (src (funcall (tqr-handler src) (cdr form)))
           ((%pq-source-p (car form))
            (error 'cairn-query-error
                   :message (format nil "~A is a pattern source; this query language has no pattern surface."
                                    (string-downcase (symbol-name (car form))))))
           ((or (sym= (car form) "union") (sym= (car form) "minus") (sym= (car form) "intersect"))
            (error 'cairn-query-error
                   :message "Set operations are pipeline steps, e.g. (-> (active) (:union (dormant)))."))
           (t (error 'cairn-query-error
                     :message (format nil "Unknown source: ~S" form))))))))

(defun interpret-pipeline (forms)
  (let ((result (interpret-expr (first forms))))
    (dolist (step (rest forms) result)
      (setf result (interpret-step result step)))))

(defun interpret-query (form)
  (interpret-expr form))

;;; --- Rendering: every result becomes text before leaving the runner ---

(defparameter +rendered-specially+
  '(:status :description :depot :created-ts :updated-ts :status-ts :parent
    :display-name :obs-count :edge-count)
  "Props rendered inline on the node line or deliberately omitted; the rest
(promoted metadata) print on their own lines.")

(defun %format-node (node)
  (let ((slug (car node)) (props (cdr node)))
    (with-output-to-string (s)
      (format s "- ~A" slug)
      (let ((display (getf props :display-name)))
        (when (and (stringp display) (not (string= display slug)))
          (format s " [~A]" display)))
      (let ((status (getf props :status)))
        (when status (format s " (~A)" status)))
      (let ((obs (getf props :obs-count)) (edges (getf props :edge-count)))
        (when obs (format s " obs=~D" obs))
        (when edges (format s " edges=~D" edges)))
      (loop for (key val) on props by #'cddr
            when (and val (not (member key +rendered-specially+)))
              do (format s "~%    ~(~A~): ~A" key val)))))

(defun %format-nodes (nodes)
  (format nil "~D task~:P:~%~{~A~%~}" (length nodes) (mapcar #'%format-node nodes)))

(defun %format-ids (ids)
  (format nil "~D task~:P:~%~{- ~A~%~}" (length ids) ids))

(defun %format-projection (proj)
  (with-output-to-string (s)
    (let ((nodes (qp-nodes proj)) (fields (qp-fields proj)))
      (format s "~D task~:P:~%" (length nodes))
      (dolist (node nodes)
        (format s "- ~A" (car node))
        (dolist (f fields)
          (let ((v (getf (cdr node) f)))
            (when v (format s "  ~(~A~)=~A" f v))))
        (terpri s)))))

(defun %format-group (grp)
  (with-output-to-string (s)
    (let ((groups (qg-groups grp)))
      (format s "~D group~:P:~%" (length groups))
      (dolist (g groups)
        (format s "~%## ~A (~D)~%" (car g) (length (cdr g)))
        (dolist (node (cdr g))
          (format s "~A~%" (%format-node node)))))))

(defun format-query-result (result)
  (cond
    ((integerp result) (format nil "~D" result))
    ((q-projection-p result) (%format-projection result))
    ((q-group-p result) (%format-group result))
    ((null result) "No matching tasks.")
    ((and (consp result) (stringp (first result))) (%format-ids result))
    ((consp result) (%format-nodes result))
    (t (format nil "~S" result))))

;;; --- Safe parse + tool runner ---

(defun safe-read-query (string)
  "Read STRING into a query form with *read-eval* disabled. Rejects nil, a
non-string, or blank input, and turns any read error into a parse error."
  (cond
    ((null string)
     (error 'cairn-query-parse-error :message "query is required."))
    ((not (stringp string))
     (error 'cairn-query-parse-error :message "query must be a string."))
    ((zerop (length (string-trim '(#\Space #\Tab #\Newline #\Return) string)))
     (error 'cairn-query-parse-error :message "query is empty.")))
  (let ((*read-eval* nil)
        (*package* (find-package :kli/cairn)))
    (handler-case (values (read-from-string string))
      (error (c)
        (error 'cairn-query-parse-error :message (princ-to-string c))))))

(defun %run-query (raw context allow-mutation)
  "Parse and interpret RAW over CONTEXT's store under the connection lock,
rendering the result to text. ALLOW-MUTATION binds the read/write gate and, when
true, the write context so a `!`-form can record an event."
  (if (%blank-p raw)
      (%fail "query is required.")
      (with-cairn-store-lock (context)
        (let ((*query-db* (context-db context))
              (*query-current* (current-task-id context))
              (*query-allow-mutation* allow-mutation)
              (*query-context* (and allow-mutation context)))
          (handler-case
              (%text (format-query-result (interpret-query (safe-read-query raw))))
            (cairn-query-parse-error (c)
              (%fail "Parse error: ~A" (cairn-query-error-message c)))
            (cairn-query-error (c)
              (%fail "Query error: ~A" (cairn-query-error-message c)))
            (sqlite:sqlite-error ()
              (%fail "The query could not be executed.")))))))

(defun run-task-query (tool parameters context &key call-id on-update)
  (declare (ignore tool call-id on-update))
  (%run-query (tool-parameter parameters :query) context nil))

(defun run-task-query-write (tool parameters context &key call-id on-update)
  (declare (ignore tool call-id on-update))
  (%run-query (tool-parameter parameters :query) context t))

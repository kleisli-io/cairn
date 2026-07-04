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

(defvar *query-fields* nil
  "The live metadata-key half of the known-field vocabulary, computed once per
query from the store. Unioned with the declared fields, it is the set field
references validate against and (fields) reflects.")

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
    (:created-ts . :timestamp) (:updated-ts . :timestamp) (:status-ts . :timestamp)
    (:obs-count . :number) (:edge-count . :number))
  "Known field -> value type. A :timestamp is CL universal-time (seconds since
1900-01-01 UTC): ordered as an integer, legible as a date. A field absent here is
open metadata, read on demand and treated as text.")

(defun %field-type (field)
  (or (cdr (assoc field +field-types+)) :text))

(defun %timestamp-field-p (field)
  (eq (%field-type field) :timestamp))

(defun %numeric-field-p (field)
  "True when FIELD compares as a number: a declared :number, or a :timestamp
ordered by its underlying universal-time integer."
  (let ((ty (%field-type field)))
    (or (eq ty :number) (eq ty :timestamp))))

(defun %field-name (field)
  "FIELD keyword as a bare downcased name string."
  (string-downcase (symbol-name field)))

(defun %colon (name)
  "A bare field/keyword NAME shown as written in a query: colon-prefixed."
  (concatenate 'string ":" name))

(defun %field-display (field)
  "FIELD shown as the caller writes it, for error text."
  (%colon (%field-name field)))

(defun %metadata-keys (db)
  "The DISTINCT open-metadata keys present in DB — the live half of the field
vocabulary, discovered per query."
  (mapcar #'first
          (sqlite:execute-to-list db
            "SELECT DISTINCT key FROM task_metadata ORDER BY key")))

(defparameter +reflection-fields+
  '(:category :kind :doc :signature :type :origin :source :class :unit :epoch)
  "The synthetic prop names the reflection sources (schema/fields/edges/views)
emit. Part of the known-field vocabulary so a predicate or projection over a
reflective node-set type-checks, even though (fields) lists only the task
projection's own fields.")

(defun %known-field-names ()
  "Every known field name as a bare string: the declared and reflection fields
unioned with the live metadata keys — the candidate set for field suggestions."
  (remove-duplicates
   (append (mapcar (lambda (ft) (%field-name (car ft))) +field-types+)
           (mapcar #'%field-name +reflection-fields+)
           *query-fields*)
   :test #'string= :from-end t))

(defun %known-field-p (field)
  "True when FIELD is a declared field, a reflection field, or a live metadata
key."
  (and (keywordp field)
       (or (assoc field +field-types+)
           (member field +reflection-fields+)
           (member (%field-name field) *query-fields* :test #'string=))
       t))

;;; --- Suggestion + date parsing: shared typed-error machinery ---

(defun %levenshtein (a b)
  "Edit distance between strings A and B (insert/delete/substitute each cost 1)."
  (let* ((m (length a)) (n (length b))
         (prev (make-array (1+ n) :element-type 'fixnum))
         (cur (make-array (1+ n) :element-type 'fixnum)))
    (dotimes (j (1+ n)) (setf (aref prev j) j))
    (dotimes (i m)
      (setf (aref cur 0) (1+ i))
      (dotimes (j n)
        (setf (aref cur (1+ j))
              (min (1+ (aref cur j))
                   (1+ (aref prev (1+ j)))
                   (+ (aref prev j) (if (char= (char a i) (char b j)) 0 1)))))
      (rotatef prev cur))
    (aref prev n)))

(defun %suggest (name candidates &key (display #'identity))
  "The 'did you mean' clause for an unknown NAME against CANDIDATES (bare name
strings): the single nearest within edit distance 3, else the known list. DISPLAY
renders a candidate for the message (e.g. colon-prefixing a field name)."
  (let ((best nil) (best-d 4))
    (dolist (c candidates)
      (let ((d (%levenshtein name c)))
        (when (< d best-d) (setf best-d d best c))))
    (if best
        (format nil "did you mean ~A?" (funcall display best))
        (format nil "known: ~{~A~^, ~}."
                (sort (mapcar display (copy-list candidates)) #'string<)))))

(defun %parse-date (string)
  "Parse a strict YYYY-MM-DD STRING to CL universal-time at UTC midnight (tz 0).
Any deviation is a structured error, so a malformed date never silently misreads
as an empty result."
  (flet ((bad () (error 'cairn-query-error
                        :message (format nil "~S is not a YYYY-MM-DD date." string))))
    (unless (and (stringp string)
                 (= (length string) 10)
                 (char= (char string 4) #\-)
                 (char= (char string 7) #\-)
                 (every #'digit-char-p (remove #\- string)))
      (bad))
    (let ((y (parse-integer string :start 0 :end 4))
          (m (parse-integer string :start 5 :end 7))
          (d (parse-integer string :start 8 :end 10)))
      (unless (and (<= 1 m 12) (<= 1 d 31)) (bad))
      ;; Round-trip to reject a normalised non-date (Feb 30 rolls to March).
      (let ((ut (handler-case (encode-universal-time 0 0 0 d m y 0) (error () (bad)))))
        (multiple-value-bind (s mi h dd mm yy) (decode-universal-time ut 0)
          (declare (ignore s mi h))
          (unless (and (= dd d) (= mm m) (= yy y)) (bad))
          ut)))))

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
                :message (format nil "Unknown edge type ~A; ~A" name
                                 (%suggest name (%known-edge-types) :display #'%colon)))))))

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

(defun %compile-numeric (form op-fn op-label)
  "Compile a numeric comparison FORM (already signature-checked). A timestamp LHS
runs an integer operand through canonical-ts, so a Unix-second literal lands on
the same universal-time clock the write path uses instead of silently sitting
below every value."
  (let* ((lhs (second form))
         (raw (third form))
         (getter (%numeric-lhs lhs op-label))
         (operand (if (and (keywordp lhs) (%timestamp-field-p lhs) (integerp raw))
                      (canonical-ts raw)
                      raw)))
    (lambda (slug props)
      (let ((v (funcall getter slug props)))
        (and (realp v) (funcall op-fn v operand))))))

;;; --- Argument signatures: one typed checker over the closed arg-kind set ---
;;
;; A signature is a list of arg-kind specs describing a form's arguments. One
;; %check-signature validates any form against its declared kinds and emits
;; uniform structured errors, so a predicate, step, or source carries its
;; argument contract as data the interpreter checks, reflection renders, and the
;; suggester corrects against. The kinds:
;;   (:field-ref text|number|timestamp|any) — a known field of the given class
;;   (:value-expr numeric|any)              — a field-ref or (count TRAV)
;;   (:literal string|real|date|any)        — a constant operand
;;   :traversal                             — (:follow EDGE) | (:back EDGE)
;;   :sub-predicate / :sub-predicate*       — a nested predicate / one-or-more
;;   :edge / :edge*                         — an edge type / one-or-more
;;   :field-list                            — one-or-more field-refs
;;   :integer / :sub-query                  — a take count / a node-set form
;;   (:enum NAME...)                        — one of the listed keywords
;;   (:opt KIND)                            — an optional trailing argument

(defun %enum-token (member)
  "An enum MEMBER as the bare token it matches on: a keyword member by its
downcased name, a string member by itself."
  (if (keywordp member) (string-downcase (symbol-name member)) member))

(defun %enum-value-token (value)
  "A caller's VALUE reduced to its enum token, or NIL when it cannot name one."
  (cond ((keywordp value) (string-downcase (symbol-name value)))
        ((stringp value) value)
        (t nil)))

(defun %kind-token (kind)
  "KIND rendered as a short machine token for the signature line and its doc."
  (flet ((q (base type) (ecase type
                          (:any base)
                          (:text (concatenate 'string base "-text"))
                          ((:number :numeric) (concatenate 'string base "-num"))
                          (:timestamp (concatenate 'string base "-ts"))
                          (:string (concatenate 'string base "-str"))
                          (:real (concatenate 'string base "-real"))
                          (:date (concatenate 'string base "-date")))))
    (cond
      ((eq kind :traversal) "traversal")
      ((eq kind :sub-predicate) "pred")
      ((eq kind :sub-predicate*) "pred...")
      ((eq kind :edge) "edge")
      ((eq kind :edge*) "edge...")
      ((eq kind :field-list) "field...")
      ((eq kind :integer) "int")
      ((eq kind :sub-query) "query")
      ((consp kind)
       (ecase (car kind)
         (:field-ref (q "field" (cadr kind)))
         (:value-expr (q "value" (cadr kind)))
         (:literal (q "lit" (cadr kind)))
         (:enum (format nil "~{~A~^|~}" (mapcar #'%enum-token (cdr kind))))
         (:opt (format nil "[~A]" (%kind-token (cadr kind))))))
      (t (string-downcase (symbol-name kind))))))

(defun %a/an (word)
  "The indefinite article agreeing with WORD's initial sound."
  (if (and (plusp (length word)) (find (char-downcase (char word 0)) "aeiou")) "an" "a"))

(defun %render-signature (signature)
  "SIGNATURE as a space-separated token line: the machine-readable contract
reflection renders and a doc derives from."
  (format nil "~{~A~^ ~}" (mapcar #'%kind-token signature)))

(defun %check-field-ref (field type head)
  (unless (keywordp field)
    (error 'cairn-query-error
           :message (format nil "~A needs a field name like :status, got ~S." head field)))
  (unless (%known-field-p field)
    (error 'cairn-query-error
           :message (format nil "Unknown field ~A; ~A" (%field-display field)
                            (%suggest (%field-name field) (%known-field-names) :display #'%colon))))
  (ecase type
    (:any t)
    (:text
     (unless (eq (%field-type field) :text)
       (error 'cairn-query-error
              :message (format nil "~A needs a text field; ~A is ~(~A~)."
                               head (%field-display field) (%field-type field)))))
    (:number
     (unless (%numeric-field-p field)
       (error 'cairn-query-error
              :message (format nil "~A needs a numeric field; ~A is ~(~A~)."
                               head (%field-display field) (%field-type field)))))
    (:timestamp
     (unless (%timestamp-field-p field)
       (error 'cairn-query-error
              :message (format nil "~A needs a timestamp field; ~A is ~(~A~)."
                               head (%field-display field) (%field-type field))))))
  t)

(defun %check-value-expr (expr numericp head)
  "EXPR is a field-ref or (count TRAV); the numeric form needs a numeric field
((count TRAV) is numeric by construction)."
  (cond
    ((keywordp expr) (%check-field-ref expr (if numericp :number :any) head))
    ((%count-expr-p expr) (%check-traversal (second expr) head))
    (t (error 'cairn-query-error
              :message (format nil "~A needs a field name or (count TRAV), got ~S." head expr))))
  t)

(defun %check-literal (value type head)
  (ecase type
    (:any t)
    (:string
     (unless (stringp value)
       (error 'cairn-query-error
              :message (format nil "~A needs a string, got ~S." head value))))
    (:real
     (unless (realp value)
       (error 'cairn-query-error
              :message (format nil "~A needs a real-number operand, got ~S." head value))))
    (:date (%parse-date value)))
  t)

(defun %check-traversal (trav head)
  (unless (and (consp trav) (member (car trav) '(:follow :back)))
    (error 'cairn-query-error
           :message (format nil "~A needs a traversal (:follow EDGE) or (:back EDGE), got ~S."
                            head trav)))
  (%edge-class (second trav))
  t)

(defun %check-enum (value members head)
  "VALUE must name one of MEMBERS (homogeneous keywords or strings). The display
follows the member style — keywords colon-prefixed, strings quoted — so the
suggestion reads as the caller would write it."
  (let* ((tokens (mapcar #'%enum-token members))
         (keyworded (keywordp (first members)))
         (display (if keyworded #'%colon (lambda (s) (format nil "~S" s))))
         (vt (%enum-value-token value)))
    (unless (and vt (member vt tokens :test #'string=))
      (error 'cairn-query-error
             :message (format nil "~A needs ~{~A~^ or ~}~@[; ~A~]"
                              head (mapcar display tokens)
                              (and vt (%suggest vt tokens :display display))))))
  t)

(defun %check-arg (kind arg head)
  "Validate one ARG against one arg-KIND for the form named HEAD."
  (cond
    ((eq kind :traversal) (%check-traversal arg head))
    ((eq kind :edge) (%edge-class arg))
    ((eq kind :integer)
     (unless (integerp arg)
       (error 'cairn-query-error
              :message (format nil "~A needs an integer, got ~S." head arg))))
    ((eq kind :sub-predicate)
     (unless (consp arg)
       (error 'cairn-query-error
              :message (format nil "~A needs a predicate like (= :status \"active\"), got ~S."
                               head arg))))
    ((eq kind :sub-query)
     (unless (consp arg)
       (error 'cairn-query-error
              :message (format nil "~A needs a sub-query, got ~S." head arg))))
    ((consp kind)
     (ecase (car kind)
       (:field-ref (%check-field-ref arg (cadr kind) head))
       (:value-expr (%check-value-expr arg (eq (cadr kind) :numeric) head))
       (:literal (%check-literal arg (cadr kind) head))
       (:enum (%check-enum arg (cdr kind) head))))
    (t (error "Internal: unknown arg-kind ~S." kind)))
  t)

(defun %check-signature (head args signature)
  "Validate ARGS (a form's cdr) against SIGNATURE, a list of arg-kind specs, for
the form named HEAD. A variadic kind (:sub-predicate*, :edge*, :field-list)
consumes the rest; (:opt KIND) allows the final argument to be absent. Signals a
structured error on any mismatch; returns T."
  (let ((rest args))
    (dolist (spec signature)
      (cond
        ((member spec '(:sub-predicate* :edge* :field-list))
         (when (null rest)
           (error 'cairn-query-error
                  :message (format nil "~A needs at least one ~A." head
                                   (ecase spec
                                     (:sub-predicate* "predicate")
                                     (:edge* "edge type")
                                     (:field-list "field")))))
         (let ((elt (ecase spec
                      (:sub-predicate* :sub-predicate)
                      (:edge* :edge)
                      (:field-list '(:field-ref :any)))))
           (dolist (a rest) (%check-arg elt a head)))
         (setf rest nil))
        ((and (consp spec) (eq (car spec) :opt))
         (when rest
           (%check-arg (cadr spec) (car rest) head)
           (setf rest (cdr rest))))
        (t
         (when (null rest)
           (let ((tok (%kind-token spec)))
             (error 'cairn-query-error
                    :message (format nil "~A needs ~A ~A argument." head (%a/an tok) tok))))
         (%check-arg spec (car rest) head)
         (setf rest (cdr rest)))))
    (when rest
      (error 'cairn-query-error
             :message (format nil "~A takes ~D argument~:P, got ~D."
                              head (length signature) (length args))))
    t))

;;; --- Predicate registry: the leaf/combinator/quantifier vocabulary ---
;;
;; Predicates are a typed registry like sources and steps, closing the one place
;; the grammar was a hardcoded cond. Each entry carries a machine-readable
;; signature the one %check-signature validates, a compiler lowering the form to
;; a (slug props)->boolean test, and a kind reflection renders. Combinators and
;; quantifiers recurse through interpret-where, so the algebra nests for free.

(defstruct (tq-predicate (:conc-name tqp-))
  (key nil :read-only t)
  (kind nil :read-only t)
  (signature nil :read-only t)
  (compiler nil :read-only t)
  (doc nil :read-only t))

(defun %compile-quantifier (test)
  "Build a quantifier compiler applying TEST (every/some/notany) to the inner
predicate over each task one traversal hop from the focus node."
  (lambda (form)
    (let ((traverse (%compile-traversal (second form)
                                        (format nil "(~A ...)" (%pred-head form))))
          (inner (interpret-where (third form)))
          (fields (%extract-fields (third form))))
      (lambda (slug props)
        (let ((nodes (%maybe-enrich *query-db*
                                    (funcall traverse (cons slug props))
                                    fields)))
          (funcall test (lambda (n) (funcall inner (car n) (cdr n))) nodes))))))

(defun %compile-date-pred (test)
  "Build a date-predicate compiler running TEST over the field's universal-time
value V and the UTC day START parsed from the operand (END = START + one day)."
  (lambda (form)
    (let* ((field (second form))
           (start (%parse-date (third form)))
           (end (+ start 86400)))
      (lambda (slug props)
        (let ((v (%field-value field slug props)))
          (and (realp v) (funcall test v start end)))))))

(defparameter +tq-predicates+
  (list
   (make-tq-predicate :key "=" :kind :leaf :signature '((:value-expr :any) (:literal :any))
     :doc "(= VALUE LIT) — VALUE (a field or (count TRAV)) equals the literal."
     :compiler (lambda (form)
                 (let ((getter (%compile-value (second form) "="))
                       (val (third form)))
                   (lambda (slug props) (equal (funcall getter slug props) val)))))
   (make-tq-predicate :key "has" :kind :leaf :signature '((:field-ref :any))
     :doc "(has FIELD) — FIELD has a non-nil value."
     :compiler (lambda (form)
                 (let ((f (second form)))
                   (lambda (slug props) (and (%field-value f slug props) t)))))
   (make-tq-predicate :key "matches" :kind :leaf
     :signature '((:field-ref :text) (:literal :string))
     :doc "(matches FIELD \"substr\") — FIELD's text contains the substring."
     :compiler (lambda (form)
                 (let ((f (second form)) (sub (third form)))
                   (lambda (slug props)
                     (let ((v (%field-value f slug props)))
                       (and (stringp v) (search sub v :test #'char-equal) t))))))
   (make-tq-predicate :key ">" :kind :leaf
     :signature '((:value-expr :numeric) (:literal :real))
     :doc "(> VALUE N) — numeric VALUE is greater than N."
     :compiler (lambda (form) (%compile-numeric form #'> ">")))
   (make-tq-predicate :key "<" :kind :leaf
     :signature '((:value-expr :numeric) (:literal :real))
     :doc "(< VALUE N) — numeric VALUE is less than N."
     :compiler (lambda (form) (%compile-numeric form #'< "<")))
   (make-tq-predicate :key ">=" :kind :leaf
     :signature '((:value-expr :numeric) (:literal :real))
     :doc "(>= VALUE N) — numeric VALUE is at least N."
     :compiler (lambda (form) (%compile-numeric form #'>= ">=")))
   (make-tq-predicate :key "on" :kind :leaf
     :signature '((:field-ref :timestamp) (:literal :date))
     :doc "(on FIELD \"YYYY-MM-DD\") — FIELD falls on the given UTC day."
     :compiler (%compile-date-pred (lambda (v start end) (and (<= start v) (< v end)))))
   (make-tq-predicate :key "since" :kind :leaf
     :signature '((:field-ref :timestamp) (:literal :date))
     :doc "(since FIELD \"YYYY-MM-DD\") — FIELD is on or after the given UTC day."
     :compiler (%compile-date-pred (lambda (v start end) (declare (ignore end)) (>= v start))))
   (make-tq-predicate :key "before" :kind :leaf
     :signature '((:field-ref :timestamp) (:literal :date))
     :doc "(before FIELD \"YYYY-MM-DD\") — FIELD is before the given UTC day."
     :compiler (%compile-date-pred (lambda (v start end) (declare (ignore end)) (< v start))))
   (make-tq-predicate :key "and" :kind :combinator :signature '(:sub-predicate*)
     :doc "(and PRED...) — every sub-predicate holds."
     :compiler (lambda (form)
                 (let ((ps (mapcar #'interpret-where (cdr form))))
                   (lambda (slug props) (every (lambda (p) (funcall p slug props)) ps)))))
   (make-tq-predicate :key "or" :kind :combinator :signature '(:sub-predicate*)
     :doc "(or PRED...) — some sub-predicate holds."
     :compiler (lambda (form)
                 (let ((ps (mapcar #'interpret-where (cdr form))))
                   (lambda (slug props) (some (lambda (p) (funcall p slug props)) ps)))))
   (make-tq-predicate :key "not" :kind :combinator :signature '(:sub-predicate)
     :doc "(not PRED) — the sub-predicate does not hold."
     :compiler (lambda (form)
                 (let ((p (interpret-where (second form))))
                   (lambda (slug props) (not (funcall p slug props))))))
   (make-tq-predicate :key "all" :kind :quantifier :signature '(:traversal :sub-predicate)
     :doc "(all TRAV PRED) — every task one TRAV hop away satisfies PRED."
     :compiler (%compile-quantifier #'every))
   (make-tq-predicate :key "any" :kind :quantifier :signature '(:traversal :sub-predicate)
     :doc "(any TRAV PRED) — some task one TRAV hop away satisfies PRED."
     :compiler (%compile-quantifier #'some))
   (make-tq-predicate :key "none" :kind :quantifier :signature '(:traversal :sub-predicate)
     :doc "(none TRAV PRED) — no task one TRAV hop away satisfies PRED."
     :compiler (%compile-quantifier #'notany)))
  "The predicate vocabulary: leaf tests, combinators, and quantifiers, each a
typed registry entry the interpreter dispatches on, the signature validates, and
reflection renders.")

(defun %find-predicate (name) (find name +tq-predicates+ :key #'tqp-key :test #'string=))
(defun %predicate-keys () (mapcar #'tqp-key +tq-predicates+))

(defun interpret-where (pred)
  "Compile a predicate form into a function of (slug props), dispatching on the
typed predicate registry. An unknown head is a structured error routed through
the suggester, never a silent mismatch."
  (unless (consp pred)
    (error 'cairn-query-error
           :message (format nil "A predicate is a form like (= :status \"active\"), got ~S." pred)))
  (let* ((head (%pred-head pred))
         (desc (and head (%find-predicate head))))
    (unless desc
      (error 'cairn-query-error
             :message (format nil "Unknown predicate ~A; ~A"
                              (if head head (format nil "~S" pred))
                              (%suggest (or head "") (%predicate-keys)))))
    (%check-signature head (cdr pred) (tqp-signature desc))
    (funcall (tqp-compiler desc) pred)))

;;; --- Projection / grouping carriers (internal; rendered in the runner) ---

(defstruct (q-projection (:conc-name qp-)) nodes fields)
(defstruct (q-group (:conc-name qg-)) field groups)

(defun %sort-by (nodes field &optional (direction :desc))
  "Sort NODES by FIELD. DIRECTION is :desc (default) or :asc. Numeric when the
field holds numbers, else lexicographic by the field's printed value. FIELD is
read with %field-value, so :slug (the node's own name) sorts as written."
  (when nodes
    (let* ((numeric (loop for n in nodes
                          for v = (%field-value field (car n) (cdr n))
                          when v return (realp v)))
           (asc (eq direction :asc))
           (order (if numeric (if asc #'< #'>) (if asc #'string< #'string>))))
      (sort (copy-list nodes)
            order
            :key (lambda (n)
                   (let ((v (%field-value field (car n) (cdr n))))
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
  (signature nil :read-only t)
  (handler nil :read-only t)
  (doc nil :read-only t))

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

(defun %edge-step (input args type)
  "Record TYPE (task.link or task.sever) from each task to a constant target. A
node equal to the target is skipped — a task does not edge to itself. The edge
type is validated against the lateral enum by the step's signature."
  (let ((edge (string-downcase (symbol-name (first args))))
        (target (%bare-slug (second args))))
    (unless (and (stringp target) (plusp (length target)))
      (error 'cairn-query-error :message "An edge mutation needs a target slug."))
    (%mutate-nodes input
                   (lambda (slug)
                     (unless (string= slug target)
                       (%record *query-context* slug type
                                (list :target-id target :edge-type edge))))
                   #'identity)))

(defun %status-enum ()
  "The status enum as an arg-kind spec: one of the closed status strings."
  (cons :enum +cairn-statuses+))

(defun %lateral-edge-enum ()
  "The lateral edge-type enum as an arg-kind spec, written as keywords."
  (cons :enum (mapcar (lambda (s) (intern (string-upcase s) :keyword))
                      +cairn-edge-types+)))

(defparameter +tq-steps+
  (list
   (make-tq-step :key :follow :kind :transformer :signature '(:edge)
                 :handler (lambda (db input args) (%follow db input (first args)))
                 :doc "(:follow EDGE) — the tasks one EDGE hop forward.")
   (make-tq-step :key :back :kind :transformer :signature '(:edge)
                 :handler (lambda (db input args) (%back db input (first args)))
                 :doc "(:back EDGE) — the tasks one EDGE hop backward.")
   (make-tq-step :key :where :kind :transformer :signature '(:sub-predicate)
                 :handler (lambda (db input args)
                            (let ((fn (interpret-where (first args)))
                                  (nodes (%maybe-enrich db input (%extract-fields (first args)))))
                              (remove-if-not (lambda (n) (funcall fn (car n) (cdr n))) nodes)))
                 :doc "(:where PRED) — the tasks satisfying PRED.")
   (make-tq-step :key :sort :kind :transformer
                 :signature '((:field-ref :any) (:opt (:enum :asc :desc)))
                 :handler (lambda (db input args)
                            (let ((field (first args))
                                  (dir (or (second args) :desc)))
                              (%sort-by (%maybe-enrich db input (list field)) field dir)))
                 :doc "(:sort FIELD [:asc|:desc]) — order by FIELD; descending by default.")
   (make-tq-step :key :take :kind :transformer :signature '(:integer)
                 :handler (lambda (db input args)
                            (declare (ignore db))
                            (%take input (max 0 (first args))))
                 :doc "(:take N) — the first N tasks.")
   (make-tq-step :key :enrich :kind :transformer :signature '()
                 :handler (lambda (db input args) (declare (ignore args)) (%enrich db input))
                 :doc "(:enrich) — add counts and promoted metadata.")
   (make-tq-step :key :union :kind :transformer :signature '(:sub-query)
                 :handler (lambda (db input args) (declare (ignore db))
                            (%union input (%operand-of args ":union")))
                 :doc "(:union Q) — tasks in the pipeline or in sub-query Q.")
   (make-tq-step :key :intersect :kind :transformer :signature '(:sub-query)
                 :handler (lambda (db input args) (declare (ignore db))
                            (%intersect input (%operand-of args ":intersect")))
                 :doc "(:intersect Q) — tasks in both the pipeline and sub-query Q.")
   (make-tq-step :key :minus :kind :transformer :signature '(:sub-query)
                 :handler (lambda (db input args) (declare (ignore db))
                            (%minus input (%operand-of args ":minus")))
                 :doc "(:minus Q) — pipeline tasks not in sub-query Q.")
   (make-tq-step :key :or-else :kind :transformer :signature '(:sub-query)
                 :handler (lambda (db input args) (declare (ignore db))
                            (if input input (%operand-of args ":or-else")))
                 :doc "(:or-else Q) — the pipeline if it holds any task, else sub-query Q.")
   (make-tq-step :key :closure :kind :transformer :signature '(:edge*)
                 :handler (lambda (db input args) (%closure-step db input args))
                 :doc "(:closure EDGE...) — the forward transitive closure over the EDGEs, cycle-safe.")
   (make-tq-step :key :select :kind :shaper :signature '(:field-list)
                 :handler (lambda (db input args)
                            (make-q-projection :nodes (%maybe-enrich db input args) :fields args))
                 :doc "(:select FIELD...) — project the named fields.")
   (make-tq-step :key :group-by :kind :shaper :signature '((:field-ref :any))
                 :handler (lambda (db input args)
                            (let ((field (first args)))
                              (%group-by (%maybe-enrich db input (list field)) field)))
                 :doc "(:group-by FIELD) — bucket by FIELD value.")
   (make-tq-step :key :ids :kind :shaper :signature '()
                 :handler (lambda (db input args) (declare (ignore db args)) (%slugs input))
                 :doc "(:ids) — the slugs only.")
   (make-tq-step :key :count :kind :shaper :signature '()
                 :handler (lambda (db input args) (declare (ignore db args)) (length input))
                 :doc "(:count) — the cardinality.")
   (make-tq-step :key :set-status! :kind :mutation :signature (list (%status-enum))
                 :handler (lambda (db input args) (declare (ignore db)) (%set-status-step input args))
                 :doc "(:set-status! STATUS) — set each task's status; converges on re-run.")
   (make-tq-step :key :set! :kind :mutation :signature '((:literal :any) (:literal :any))
                 :handler (lambda (db input args) (declare (ignore db)) (%set-meta-step input args))
                 :doc "(:set! :key \"value\") — set a metadata field on each task.")
   (make-tq-step :key :link! :kind :mutation
                 :signature (list (%lateral-edge-enum) '(:literal :string))
                 :handler (lambda (db input args) (declare (ignore db)) (%edge-step input args "task.link"))
                 :doc "(:link! :edge \"target\") — add an edge from each task to target.")
   (make-tq-step :key :unlink! :kind :mutation
                 :signature (list (%lateral-edge-enum) '(:literal :string))
                 :handler (lambda (db input args) (declare (ignore db)) (%edge-step input args "task.sever"))
                 :doc "(:unlink! :edge \"target\") — remove the edge from each task to target."))
  "The step vocabulary: transformers compose, shapers terminate, mutations write.
Each entry carries the machine-readable :signature the one %check-signature
validates and reflection renders.")

(defun %find-step (key) (find key +tq-steps+ :key #'tqs-key))
(defun %step-keys () (mapcar (lambda (s) (%field-name (tqs-key s))) +tq-steps+))

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
       (%check-signature (%field-display (tqs-key desc)) (cdr step) (tqs-signature desc))
       (funcall (tqs-handler desc) *query-db* result (cdr step)))
      ((and (%mutation-form-p step) (not *query-allow-mutation*))
       (%refuse-mutation))
      (t (let ((name (and (symbolp (car step)) (%field-name (car step)))))
           (error 'cairn-query-error
                  :message (if name
                               (format nil "Unknown step ~A; ~A" (%colon name)
                                       (%suggest name (%step-keys) :display #'%colon))
                               (format nil "A step is a form like (:follow :phase-of), got ~S." step))))))))

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
  "The queryable field vocabulary: each declared field a node of :origin
\"declared\" carrying its :type, and each live metadata key a node of :origin
\"metadata\" and :type \"text\". A timestamp field also carries its :unit and
:epoch, so a date intent is expressible without reverse-engineering the clock. A
declared name is never re-listed as metadata."
  (let* ((declared
           (mapcar (lambda (ft)
                     (let* ((field (car ft))
                            (type (string-downcase (symbol-name (cdr ft)))))
                       (cons (%field-name field)
                             (append (list :origin "declared" :type type)
                                     (when (%timestamp-field-p field)
                                       (list :unit "seconds"
                                             :epoch "1900-01-01 UTC (CL universal-time)"))))))
                   +field-types+))
         (declared-names (mapcar #'car declared))
         (metadata
           (loop for key in *query-fields*
                 unless (member key declared-names :test #'string=)
                   collect (cons key (list :origin "metadata" :type "text")))))
    (%sort-nodes (append declared metadata))))

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
  "The combinator grammar as a node-set: every source, step, predicate, and write
form a node tagged by :category; steps and predicates carry their :kind and the
machine-readable :signature the one validator checks; each carries its :doc.
Generated from the registries the interpreter dispatches on, so the grammar
cannot drift from behavior; (schema) lists itself and the other reflective
sources."
  (flet ((sig-prop (signature)
           (let ((rendered (%render-signature signature)))
             (unless (string= rendered "") (list :signature rendered)))))
    (%sort-nodes
     (append
      (mapcar (lambda (s)
                (cons (tqr-name s) (list :category "source" :doc (tqr-doc s))))
              +tq-sources+)
      (mapcar (lambda (s)
                (cons (string-downcase (symbol-name (tqs-key s)))
                      (append (list :category "step"
                                    :kind (string-downcase (symbol-name (tqs-kind s))))
                              (sig-prop (tqs-signature s))
                              (list :doc (tqs-doc s)))))
              +tq-steps+)
      (mapcar (lambda (p)
                (cons (tqp-key p)
                      (append (list :category "predicate"
                                    :kind (string-downcase (symbol-name (tqp-kind p))))
                              (sig-prop (tqp-signature p))
                              (list :doc (tqp-doc p)))))
              +tq-predicates+)
      (mapcar (lambda (w)
                (cons (tqw-name w) (list :category "write" :doc (tqw-doc w))))
              +tq-write-forms+)))))

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
           (t (let ((name (%pred-head form)))
                (error 'cairn-query-error
                       :message (if name
                                    (format nil "Unknown source ~A; ~A" name
                                            (%suggest name (mapcar #'tqr-name +tq-sources+)))
                                    (format nil "A query is a source form like (all) or (node \"x\"), got ~S." form))))))))))

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

(defun %iso-date (ut)
  "Universal-time UT as a YYYY-MM-DD string at UTC (tz 0), so a projected
timestamp reads as a date without leaving the integer clock behind."
  (multiple-value-bind (s mi h d m y) (decode-universal-time ut 0)
    (declare (ignore s mi h))
    (format nil "~4,'0D-~2,'0D-~2,'0D" y m d)))

(defun %format-field-value (field slug props)
  "FIELD's projected value as text: a timestamp shows its raw integer and decoded
UTC date, an absent value the empty-set glyph, anything else its printed value.
Read with %field-value, so :slug projects the node's own name, not a blank."
  (let ((v (%field-value field slug props)))
    (cond
      ((null v) "∅")
      ((and (%timestamp-field-p field) (integerp v))
       (format nil "~D (~A)" v (%iso-date v)))
      (t (princ-to-string v)))))

(defun %format-projection (proj)
  "Render every selected field on every row — an absent value as ∅, never a
dropped column — so the projection is rectangular and a nil is visible."
  (with-output-to-string (s)
    (let ((nodes (qp-nodes proj)) (fields (qp-fields proj)))
      (format s "~D task~:P:~%" (length nodes))
      (dolist (node nodes)
        (format s "- ~A" (car node))
        (dolist (f fields)
          (format s "  ~(~A~)=~A" f (%format-field-value f (car node) (cdr node))))
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
              (*query-context* (and allow-mutation context))
              (*query-fields* (%metadata-keys (context-db context))))
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

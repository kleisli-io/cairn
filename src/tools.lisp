(in-package #:kli/cairn)

;;; Native tool runners over the store. Each resolves its database handle and
;;; session from the protocol context at call time, never closing over either at
;;; build time, and serializes connection access through the per-protocol mutex.
;;; Writes go through the one durable boundary (record-event); a thin pointer
;;; notification rides the bus only after a durable append, so the bus mirrors
;;; the log and never gates it.

;;; --- Result + write helpers ---

(defun %text (string)
  (make-tool-result :content (list (make-tool-text-content string))))

(defun %fail (format &rest args)
  (make-tool-result
   :content (list (make-tool-text-content (apply #'format nil format args)))
   :error-p t))

(defun %emit-observation (context task-slug seq)
  "Best-effort bus pointer to a durable append: payload is (task-id seq), never
the record. No-op without an events provider or active protocol."
  (let* ((protocol (active-protocol context))
         (events (and protocol
                      (find-capability-provider protocol :events
                                                :contract :events/v1))))
    (when events
      (provider-call events :emit-event context
                     (provider-call events :make-event :cairn/observation
                                    :payload (list :task-id task-slug :seq seq)
                                    :source :cairn)))))

(defun %record (context task-slug type payload)
  "Append one event through the durable boundary, stamping the host session, and
emit the bus pointer on a non-duplicate append. Returns the new seq or NIL.
Callers hold the connection mutex."
  (let ((seq (record-event (context-db context) task-slug type payload
                           :session (current-session-id context))))
    (when seq (%emit-observation context task-slug seq))
    seq))

(defun %blank-p (s) (or (null s) (and (stringp s) (zerop (length s)))))

(defun %limit (raw default &optional (cap 200))
  (let ((n (cond ((integerp raw) raw)
                 ((and (stringp raw) (plusp (length raw)))
                  (or (ignore-errors (parse-integer raw :junk-allowed t)) default))
                 (t default))))
    (max 1 (min cap (or n default)))))

(defun %today-prefix ()
  "Today's UTC date as YYYY-MM-DD, the task-slug namespace."
  (multiple-value-bind (s m h day month year)
      (decode-universal-time (get-universal-time) 0)
    (declare (ignore s m h))
    (format nil "~4,'0D-~2,'0D-~2,'0D" year month day)))

(defun %date-namespace-p (slug)
  "True when SLUG opens with a YYYY-MM-DD- date namespace."
  (and (>= (length slug) 11)
       (char= (char slug 4) #\-)
       (char= (char slug 7) #\-)
       (char= (char slug 10) #\-)
       (every #'digit-char-p (subseq slug 0 4))
       (every #'digit-char-p (subseq slug 5 7))
       (every #'digit-char-p (subseq slug 8 10))))

(defun %strip-date-namespace (slug)
  "SLUG with every leading YYYY-MM-DD- date namespace removed. The namespace is
system-owned (the creation date), so a name the caller already date-prefixed is
stripped back to its descriptive core rather than doubling the prefix."
  (loop with s = slug
        while (%date-namespace-p s)
        do (setf s (subseq s 11))
        finally (return s)))

(defun %mint-slug (name)
  "A bare, date-prefixed task slug from a freeform NAME. Any leading date
namespace the caller supplied is dropped before today's is stamped, so minting
is idempotent and the prefix stays singular. Errors when nothing descriptive can
be recovered."
  (let* ((slug (%strip-date-namespace
                (kli/cairn/validation:slugify (or name ""))))
         (result (kli/cairn/validation:validate-task-name slug)))
    (unless (kli/cairn/validation:validation-result-valid-p result)
      (error "~S is not descriptive enough for a task name: ~A"
             name (kli/cairn/validation:validation-result-reason result)))
    (format nil "~A-~A" (%today-prefix) slug)))

(defun %edge-type (raw &optional default)
  "Lower-cased edge type from RAW, falling back to DEFAULT. Errors when the
result is outside the closed enum."
  (let ((et (if (%blank-p raw) default (string-downcase raw))))
    (cond
      ((null et) (error "edge_type is required."))
      ((member et +cairn-edge-types+ :test #'string=) et)
      (t (error "~S is not a valid edge type; expected one of ~{~A~^, ~}."
                et +cairn-edge-types+)))))

;;; --- Write tools ---

(defun run-observe (tool parameters context &key call-id on-update)
  (declare (ignore tool call-id on-update))
  (let ((text (tool-parameter parameters :text)))
    (if (%blank-p text)
        (%fail "text is required.")
        (let ((task (resolve-target-task parameters context)))
          (with-cairn-store-lock (context)
            (%record context task "observation" (list :text text)))
          (%text (format nil "Observed on ~A." task))))))

(defun run-task-create (tool parameters context &key call-id on-update)
  (declare (ignore tool call-id on-update))
  (let ((name (tool-parameter parameters :name)))
    (if (%blank-p name)
        (%fail "name is required.")
        (let ((slug (%mint-slug name)))
          (with-cairn-store-lock (context)
            (%record context slug "task.create"
                     (list :description (tool-parameter parameters :description)
                           :project-id (current-project-id context))))
          (unless (current-task-id context)
            (setf (current-task-id context) slug))
          (%text (format nil "Created ~A." slug))))))

(defun run-task-fork (tool parameters context &key call-id on-update)
  (declare (ignore tool call-id on-update))
  (let ((name (tool-parameter parameters :name)))
    (if (%blank-p name)
        (%fail "name is required.")
        (let ((parent (or (%bare-slug (tool-parameter parameters :from))
                          (current-task-id context)
                          (error "No parent task; pass from or select a task first.")))
              (child (%mint-slug name))
              (edge (%edge-type (tool-parameter parameters :edge_type) "phase-of")))
          (if (string= child parent)
              (%fail "A task cannot fork from itself.")
              (progn
                (with-cairn-store-lock (context)
                  (%record context child "task.create"
                           (list :description (tool-parameter parameters :description)
                                 :project-id (current-project-id context)))
                  (%record context parent "task.fork"
                           (list :child-id child :edge-type edge)))
                (setf (current-task-id context) child)
                (%text (format nil "Forked ~A from ~A (~A)." child parent edge))))))))

(defun run-task-link (tool parameters context &key call-id on-update)
  (declare (ignore tool call-id on-update))
  (let ((target (%bare-slug (tool-parameter parameters :target_id))))
    (if (null target)
        (%fail "target_id is required.")
        (let ((src (resolve-target-task parameters context))
              (edge (%edge-type (tool-parameter parameters :edge_type))))
          (if (string= src target)
              (%fail "A task cannot link to itself.")
              (progn
                (with-cairn-store-lock (context)
                  (%record context src "task.link"
                           (list :target-id target :edge-type edge)))
                (%text (format nil "Linked ~A -> ~A (~A)." src target edge))))))))

(defun run-task-sever (tool parameters context &key call-id on-update)
  (declare (ignore tool call-id on-update))
  (let ((target (%bare-slug (tool-parameter parameters :target_id))))
    (if (null target)
        (%fail "target_id is required.")
        (let ((src (resolve-target-task parameters context))
              (edge (%edge-type (tool-parameter parameters :edge_type))))
          (with-cairn-store-lock (context)
            (%record context src "task.sever" (list :target-id target :edge-type edge)))
          (%text (format nil "Severed ~A -> ~A (~A)." src target edge))))))

(defun run-task-set-metadata (tool parameters context &key call-id on-update)
  (declare (ignore tool call-id on-update))
  (let ((key (tool-parameter parameters :key)))
    (if (%blank-p key)
        (%fail "key is required.")
        (let ((task (resolve-target-task parameters context)))
          (with-cairn-store-lock (context)
            (%record context task "task.set-metadata"
                     (list :key key :value (or (tool-parameter parameters :value) ""))))
          (%text (format nil "Set ~A on ~A." key task))))))

(defun run-task-update-status (tool parameters context &key call-id on-update)
  (declare (ignore tool call-id on-update))
  (let* ((raw (tool-parameter parameters :status))
         (status (cond ((not (%blank-p raw)) (string-downcase raw))
                       ((tool-parameter parameters :reopen) "active")
                       (t nil))))
    (cond
      ((null status) (%fail "status is required."))
      ((not (status-valid-p status))
       (%fail "~S is not a valid status; expected one of ~{~A~^, ~}."
              status +cairn-statuses+))
      (t (let ((task (resolve-target-task parameters context)))
           (with-cairn-store-lock (context)
             (%record context task "task.update-status" (list :status status)))
           (%text (format nil "~A is now ~A." task status)))))))

(defun %handoff-stamp ()
  "Now as YYYY-MM-DD_HH-MM-SS in UTC, the handoff filename prefix."
  (multiple-value-bind (s m h day month year)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0D_~2,'0D-~2,'0D-~2,'0D"
            year month day h m s)))

(defun %handoff-filename (summary)
  "A timestamped, slugified filename for a handoff over SUMMARY."
  (let ((slug (kli/cairn/validation:slugify summary)))
    (format nil "~A_~A.md"
            (%handoff-stamp)
            (if (plusp (length slug)) slug "handoff"))))

(defun %handoff-skeleton (db slug summary)
  "A minimal but valid handoff document: frontmatter, a deterministic state
snapshot, and empty sections the author overwrites."
  (format nil "---~%task: ~A~%created: ~A~%summary: ~A~%---~%~%# Handoff — ~A~%~%~
               ## State~%~%~A~%## Recent work~%~%- ~%~%## Next steps~%~%- ~%"
          slug (%handoff-stamp) summary slug
          (or (%task-get-text db slug) (format nil "~A — (no recorded state)~%" slug))))

(defun run-handoff (tool parameters context &key call-id on-update)
  "Scaffold a resumable handoff: mint a path under the task scratchpad, write a
skeleton, record the event, and return the path. Deterministic — it never drives
an authoring turn; the caller overwrites the skeleton with the rich body."
  (declare (ignore tool call-id on-update))
  (let ((summary (tool-parameter parameters :summary)))
    (if (%blank-p summary)
        (%fail "summary is required.")
        (let* ((task (resolve-target-task parameters context))
               (given (tool-parameter parameters :path))
               (path (if (%blank-p given)
                         (namestring
                          (cairn-handoff-path task (%handoff-filename summary) context))
                         given)))
          (with-cairn-store-lock (context)
            (ensure-directories-exist path)
            (unless (probe-file path)
              (with-open-file (out path :direction :output
                                        :if-does-not-exist :create
                                        :if-exists :supersede)
                (write-string (%handoff-skeleton (context-db context) task summary) out)))
            (%record context task "handoff.create"
                     (list :summary summary :path path)))
          (%text (format nil "Handoff scaffolded for ~A at ~A" task path))))))

;;; --- Read tools ---

(defun %observation-count (db id)
  "Total observations recorded against task row ID."
  (sqlite:execute-single db
    "SELECT count(*) FROM observations WHERE task_id = ?" id))

(defun %earlier-observations-pointer (total shown)
  "One line pointing at the full observation history when TOTAL exceeds the SHOWN
count, else NIL. Restores discoverability where the capped read stops at SHOWN."
  (when (> total shown)
    (format nil "… ~D earlier observation~:P — call timeline with full=true, types=observation to read them all"
            (- total shown))))

(defun %render-task-get (slug status description parent children edges meta obs
                         &optional pointer)
  (with-output-to-string (out)
    (format out "~A  [~A]~%" slug status)
    (unless (%blank-p description)
      (format out "  ~A~%" description))
    (when parent (format out "  parent: ~A~%" parent))
    (when children
      (format out "  children: ~{~A~^, ~}~%" children))
    (when edges
      (format out "  edges:~%")
      (dolist (e edges)
        (format out "    ~A ~A~%" (second e) (first e))))
    (when meta
      (format out "  metadata:~%")
      (dolist (m meta)
        (format out "    ~A = ~A~%" (first m) (second m))))
    (when obs
      (format out "  recent:~%")
      (dolist (o obs)
        (format out "    - ~A~%" (first o)))
      (when pointer (format out "    ~A~%" pointer)))))

(defun %task-get-text (db slug &key (observations t))
  "Rendered computed state for SLUG over DB, or NIL when no such task.
OBSERVATIONS NIL omits the recent-observations section, leaving the
operator-authority structural frame."
  (let ((row (first (sqlite:execute-to-list db
                      "SELECT id, status, description FROM tasks WHERE slug = ?"
                      slug))))
    (when row
      (destructuring-bind (id status description) row
        (let ((obs (when observations
                     (sqlite:execute-to-list db
                       "SELECT text FROM observations WHERE task_id = ?
                         ORDER BY ts DESC, obs_id DESC LIMIT 5" id))))
          (%render-task-get
           slug status description
           (sqlite:execute-single db
             "SELECT p.slug FROM tasks c JOIN tasks p ON c.parent_task_id = p.id
               WHERE c.id = ?" id)
           (mapcar #'first (sqlite:execute-to-list db
                             "SELECT slug FROM tasks WHERE parent_task_id = ?
                               ORDER BY slug" id))
           (sqlite:execute-to-list db
             "SELECT d.slug, e.type FROM edges e JOIN tasks d ON e.dst_id = d.id
               WHERE e.src_id = ? ORDER BY e.type, d.slug" id)
           (sqlite:execute-to-list db
             "SELECT key, value FROM task_metadata WHERE task_id = ? ORDER BY key" id)
           obs
           (and obs (%earlier-observations-pointer
                     (%observation-count db id) (length obs)))))))))

(defun %task-operator-frame (db slug)
  "Non-poisonable structural frame for SLUG: slug, status, parent, children,
edges. Excludes description, metadata, and observations -- all model-authored free
text, which belongs in the fenced reference channel, never the operator one.
NIL when no such task."
  (let ((row (first (sqlite:execute-to-list db
                      "SELECT id, status FROM tasks WHERE slug = ?" slug))))
    (when row
      (destructuring-bind (id status) row
        (%render-task-get
         slug status nil
         (sqlite:execute-single db
           "SELECT p.slug FROM tasks c JOIN tasks p ON c.parent_task_id = p.id
             WHERE c.id = ?" id)
         (mapcar #'first (sqlite:execute-to-list db
                           "SELECT slug FROM tasks WHERE parent_task_id = ?
                             ORDER BY slug" id))
         (sqlite:execute-to-list db
           "SELECT d.slug, e.type FROM edges e JOIN tasks d ON e.dst_id = d.id
             WHERE e.src_id = ? ORDER BY e.type, d.slug" id)
         nil
         nil)))))

(defun %task-free-text (db slug)
  "Model-authored free text for SLUG: description and metadata key/values.
Reference (fenced) data, never operator authority. NIL when there is none."
  (let ((row (first (sqlite:execute-to-list db
                      "SELECT id, description FROM tasks WHERE slug = ?" slug))))
    (when row
      (destructuring-bind (id description) row
        (let* ((meta (sqlite:execute-to-list db
                       "SELECT key, value FROM task_metadata WHERE task_id = ?
                         ORDER BY key" id))
               (s (with-output-to-string (out)
                    (unless (%blank-p description)
                      (format out "description: ~A~%" description))
                    (when meta
                      (format out "metadata:~%")
                      (dolist (m meta)
                        (format out "  ~A = ~A~%" (first m) (second m)))))))
          (when (plusp (length s)) s))))))

(defun run-task-get (tool parameters context &key call-id on-update)
  (declare (ignore tool call-id on-update))
  (let ((slug (resolve-target-task parameters context)))
    (with-cairn-store-lock (context)
      (let ((text (%task-get-text (context-db context) slug)))
        (if text (%text text) (%fail "No task ~A." slug))))))

(defun %event-oneline (string n)
  "STRING as a single line — runs of whitespace collapse to one space, leading
space dropped — truncated to N characters with a trailing ellipsis."
  (let ((collapsed
          (with-output-to-string (out)
            (let ((in-space t))
              (loop for ch across string do
                (if (member ch '(#\Space #\Tab #\Newline #\Return #\Page))
                    (progn (unless in-space (write-char #\Space out))
                           (setf in-space t))
                    (progn (write-char ch out)
                           (setf in-space nil))))))))
    (let ((trimmed (string-right-trim '(#\Space) collapsed)))
      (if (> (length trimmed) n)
          (concatenate 'string (subseq trimmed 0 n) "…")
          trimmed))))

(defun %event-digest (type data)
  "A one-line summary of an event's payload, keyed by TYPE; empty when the type
carries no salient field."
  (flet ((d (k) (getf data k)))
    (cond
      ((string= type "observation") (or (d :text) ""))
      ((or (string= type "handoff.create") (string= type "handoff"))
       (format nil "~@[~A~]~@[ → ~A~]" (d :summary) (d :path)))
      ((string= type "task.create") (or (d :description) ""))
      ((string= type "task.update-status") (format nil "→ ~A" (or (d :status) "?")))
      ((string= type "task.set-metadata") (format nil "~A = ~A" (d :key) (d :value)))
      ((string= type "task.fork") (format nil "fork ~A~@[ (~A)~]" (d :child-id) (d :edge-type)))
      ((string= type "task.link") (format nil "→ ~A~@[ (~A)~]" (d :target-id) (d :edge-type)))
      ((string= type "task.sever") (format nil "sever ~A~@[ (~A)~]" (d :target-id) (d :edge-type)))
      ((string= type "task.reclassify")
       (format nil "~A: ~A → ~A" (d :target-id) (d :old-type) (d :new-type)))
      ((string= type "task.spawn") (format nil "spawn ~A~@[ — ~A~]" (d :child-id) (d :reason)))
      ((string= type "artifact.create") (format nil "~A~@[ [~A]~]" (d :path) (d :kind)))
      (t ""))))

(defun %split-comma (string)
  "STRING split on commas into substrings, without trimming."
  (let ((parts '()) (start 0))
    (loop for pos = (position #\, string :start start)
          do (push (subseq string start (or pos (length string))) parts)
             (if pos (setf start (1+ pos)) (return)))
    (nreverse parts)))

(defun %parse-types (raw)
  "RAW comma-separated type filter as a list of trimmed, non-empty type strings;
NIL (meaning all types) when RAW is blank."
  (unless (%blank-p raw)
    (remove-if (lambda (s) (zerop (length s)))
               (mapcar (lambda (s) (string-trim '(#\Space #\Tab) s))
                       (%split-comma raw)))))

(defun %seq-bound (raw name)
  "RAW as an integer seq bound; NIL when blank. A non-integer is a caller error
named by NAME, never a silent misread."
  (cond ((null raw) nil)
        ((integerp raw) raw)
        ((and (stringp raw) (%blank-p raw)) nil)
        ((stringp raw)
         (handler-case (parse-integer (string-trim '(#\Space) raw))
           (error () (error "~A must be an integer, got ~S." name raw))))
        (t (error "~A must be an integer." name))))

(defun %unknown-timeline-type (db types)
  "The first requested TYPE absent from DB's live event vocabulary, paired with a
nearest-match hint; NIL when every requested type exists. Guards a typo from
silently yielding an empty timeline."
  (when types
    (let ((known (mapcar #'first
                         (sqlite:execute-to-list db
                           "SELECT DISTINCT type FROM events ORDER BY type"))))
      (dolist (ty types)
        (unless (member ty known :test #'string=)
          (return (cons ty (%suggest ty known))))))))

(defun %timeline-events (db slug types before after limit)
  "Rows (seq type data ts) for SLUG, newest seq first, filtered to TYPES
(NIL = all) and the exclusive seq window (AFTER, BEFORE) (a NIL bound is open),
capped at LIMIT."
  (let ((sql (with-output-to-string (q)
               (write-string "SELECT seq, type, data, ts FROM events WHERE task_id = ?" q)
               (when types (format q " AND type IN (~{~*?~^, ~})" types))
               (when before (write-string " AND seq < ?" q))
               (when after (write-string " AND seq > ?" q))
               (write-string " ORDER BY seq DESC LIMIT ?" q)))
        (args (append (list slug) types
                      (when before (list before))
                      (when after (list after))
                      (list limit))))
    (apply #'sqlite:execute-to-list db sql args)))

(defun %timeline-remaining (db slug types after cursor)
  "Count of events older than CURSOR (seq < CURSOR) still matching SLUG, the TYPES
filter, and the AFTER floor — the events a continuation page would surface."
  (let ((sql (with-output-to-string (q)
               (write-string "SELECT count(*) FROM events WHERE task_id = ? AND seq < ?" q)
               (when types (format q " AND type IN (~{~*?~^, ~})" types))
               (when after (write-string " AND seq > ?" q))))
        (args (append (list slug cursor) types (when after (list after)))))
    (apply #'sqlite:execute-single db sql args)))

(defun %utc-minute (universal-time)
  "UNIVERSAL-TIME as YYYY-MM-DD HH:MM in UTC, minute precision."
  (multiple-value-bind (s m h day month year) (decode-universal-time universal-time 0)
    (declare (ignore s))
    (format nil "~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D" year month day h m)))

(defun %write-indented (out text indent)
  "Write TEXT to OUT, prefixing every line with INDENT and preserving newlines."
  (with-input-from-string (in text)
    (loop for line = (read-line in nil nil)
          while line
          do (write-string indent out) (write-string line out) (terpri out))))

(defun %render-timeline-digest (out row)
  "One-line digest row, byte-for-byte the historical timeline rendering."
  (destructuring-bind (seq type data ts) row
    (declare (ignore ts))
    (let ((digest (%event-oneline
                   (%event-digest type (%json->lisp (com.inuoe.jzon:parse data)))
                   140)))
      (format out "  ~D  ~A~@[  ~A~]~%"
              seq type
              (and (plusp (length digest)) digest)))))

(defun %render-timeline-full (out row)
  "Header line `<seq>  <type>  (<utc> UTC)` then the verbatim event body: an
indented block when multi-line, inline when short, nothing when empty. No
whitespace collapse, no length cut."
  (destructuring-bind (seq type data ts) row
    (let ((body (%event-digest type (%json->lisp (com.inuoe.jzon:parse data)))))
      (format out "~D  ~A  (~A UTC)" seq type (%utc-minute ts))
      (cond
        ((zerop (length body)) (terpri out))
        ((find #\Newline body) (terpri out) (%write-indented out body "    "))
        (t (format out "  ~A~%" body))))))

(defparameter *cairn-timeline-output-budget-chars* 16000
  "Soft ceiling on timeline body output. When the next event would push the body
past it, emission stops and prints a continuation cursor instead of the event.
A safety backstop independent of limit and of full; at least one event always
emits so a single oversized event can still be read.")

(defun %emit-timeline (out db slug rows full types after)
  "Render ROWS into OUT newest-first, stopping before the first event that would
push the rendered body past *cairn-timeline-output-budget-chars* and printing a
continuation cursor naming the before_seq to resume from. Below the budget the
output is exactly the per-event rendering, nothing added."
  (let ((budget *cairn-timeline-output-budget-chars*)
        (used 0)
        (last-seq nil))
    (dolist (r rows)
      (let ((chunk (with-output-to-string (s)
                     (if full
                         (%render-timeline-full s r)
                         (%render-timeline-digest s r)))))
        (when (and last-seq (> (+ used (length chunk)) budget))
          (format out "… truncated at ~D chars; ~D event~:P remaining; pass before_seq=~D to continue~%"
                  used (%timeline-remaining db slug types after last-seq) last-seq)
          (return))
        (write-string chunk out)
        (incf used (length chunk))
        (setf last-seq (first r))))))

(defun run-timeline (tool parameters context &key call-id on-update)
  (declare (ignore tool call-id on-update))
  (let ((slug (resolve-target-task parameters context))
        (limit (%limit (tool-parameter parameters :limit) 20))
        (types (%parse-types (tool-parameter parameters :types)))
        (before (%seq-bound (tool-parameter parameters :before_seq) "before_seq"))
        (after (%seq-bound (tool-parameter parameters :after_seq) "after_seq"))
        (full (tool-parameter parameters :full)))
    (with-cairn-store-lock (context)
      (let* ((db (context-db context))
             (bad (%unknown-timeline-type db types)))
        (if bad
            (%fail "unknown event type ~S; ~A" (car bad) (cdr bad))
            (let ((rows (%timeline-events db slug types before after limit)))
              (%text
               (with-output-to-string (out)
                 (format out "~A — last ~D events~%" slug (length rows))
                 (%emit-timeline out db slug rows full types after)))))))))

;;; --- Orientation: one-call bootstrap ---

(defun %recent-task-slugs (db &optional (limit 5))
  (mapcar #'first (sqlite:execute-to-list db
                    "SELECT slug FROM tasks ORDER BY updated_ts DESC LIMIT ?" limit)))

(defun %like-escape (string)
  "STRING with the LIKE metacharacters % and _ and the escape char \\ each
backslash-escaped, for a pattern run under ESCAPE '\\'."
  (with-output-to-string (out)
    (loop for ch across string do
      (when (member ch '(#\% #\_ #\\)) (write-char #\\ out))
      (write-char ch out))))

(defun %search-task-slugs (db query &optional limit)
  "(slug . description) candidates for QUERY over DB, recent-first and excluding
the @-namespaced internal slugs, so the completion popup can scroll the full set.
A blank QUERY lists every task most-recent-first; otherwise prefix matches
(index-backed) rank above substring matches (a bounded scan), each ordered by
recency. LIMIT caps the row count when given, else the result is unbounded.
Descriptions collapse to one line; a blank description yields the bare slug."
  (flet ((shape (row)
           (destructuring-bind (slug description) row
             (if (%blank-p description)
                 slug
                 (cons slug (%event-oneline description 80))))))
    (let ((cap (if limit (format nil " LIMIT ~D" (max 1 limit)) "")))
      (mapcar #'shape
              (if (%blank-p query)
                  (sqlite:execute-to-list db
                    (concatenate 'string
                      "SELECT slug, description FROM tasks WHERE slug NOT LIKE '@%'
                        ORDER BY updated_ts DESC" cap))
                  (let ((esc (%like-escape query)))
                    (sqlite:execute-to-list db
                      (concatenate 'string
                        "SELECT slug, description FROM tasks
                          WHERE slug LIKE ? ESCAPE '\\' AND slug NOT LIKE '@%'
                          ORDER BY (slug LIKE ? ESCAPE '\\') DESC, updated_ts DESC"
                        cap)
                      (format nil "%~A%" esc) (format nil "~A%" esc))))))))

(defun %open-handoffs-text (db slug &optional (limit 3))
  "The latest handoff summaries for SLUG, or NIL when none."
  (let ((rows (sqlite:execute-to-list db
                "SELECT h.summary, h.path FROM handoffs h JOIN tasks t ON h.task_id = t.id
                  WHERE t.slug = ? ORDER BY h.ts DESC LIMIT ?" slug limit)))
    (when rows
      (with-output-to-string (out)
        (format out "  handoffs:~%")
        (dolist (r rows)
          (destructuring-bind (summary path) r
            (format out "    - ~A~@[ (~A)~]~%"
                    summary (and (stringp path) (plusp (length path)) path))))))))

(defun run-task-bootstrap (tool parameters context &key call-id on-update)
  "One-call orientation on a task: computed state, neighbors, open handoffs, and
recent observations. An explicit task_id switches the current pointer to that
task — orienting on a task makes it current, so spawned sessions and the injected
context agree on which task is in focus. With no task_id, orients on the current
task and adopts it only when none is set. Records no event; switches the pointer
only after the task is found."
  (declare (ignore tool call-id on-update))
  (let* ((explicit (%bare-slug (tool-parameter parameters :task_id)))
         (target (or explicit (current-task-id context))))
    (if (null target)
        (%fail "No task to bootstrap; pass task_id or select a task first.")
        (with-cairn-store-lock (context)
          (let* ((db (context-db context))
                 (state (%task-get-text db target)))
            (if (null state)
                (%fail "No task ~A.~@[ Recent: ~{~A~^, ~}~]"
                       target (%recent-task-slugs db))
                (progn
                  (when (or explicit (null (current-task-id context)))
                    (setf (current-task-id context) target))
                  (%text
                   (with-output-to-string (out)
                     (write-string state out)
                     (let ((h (%open-handoffs-text db target)))
                       (when h (write-string h out))))))))))))

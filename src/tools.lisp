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

(defun %mint-slug (name)
  "A bare, date-prefixed task slug from a freeform NAME. Errors when nothing
descriptive can be recovered."
  (let* ((slug (kli/cairn/validation:slugify (or name "")))
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

(defun %render-task-get (slug status description parent children edges meta obs)
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
        (format out "    - ~A~%" (first o))))))

(defun %task-get-text (db slug)
  "Rendered computed state for SLUG over DB, or NIL when no such task."
  (let ((row (first (sqlite:execute-to-list db
                      "SELECT id, status, description FROM tasks WHERE slug = ?"
                      slug))))
    (when row
      (destructuring-bind (id status description) row
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
         (sqlite:execute-to-list db
           "SELECT text FROM observations WHERE task_id = ?
             ORDER BY ts DESC, obs_id DESC LIMIT 5" id))))))

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

(defun run-timeline (tool parameters context &key call-id on-update)
  (declare (ignore tool call-id on-update))
  (let ((slug (resolve-target-task parameters context))
        (limit (%limit (tool-parameter parameters :limit) 20)))
    (with-cairn-store-lock (context)
      (let ((rows (sqlite:execute-to-list (context-db context)
                    "SELECT seq, type, data FROM events WHERE task_id = ?
                      ORDER BY seq DESC LIMIT ?" slug limit)))
        (%text
         (with-output-to-string (out)
           (format out "~A — last ~D events~%" slug (length rows))
           (dolist (r rows)
             (destructuring-bind (seq type data) r
               (let ((digest (%event-oneline
                              (%event-digest type (%json->lisp (com.inuoe.jzon:parse data)))
                              140)))
                 (format out "  ~D  ~A~@[  ~A~]~%"
                         seq type
                         (and (plusp (length digest)) digest)))))))))))

;;; --- Orientation: one-call bootstrap + swarm readout ---

(defun %session-abbrev (sid)
  (if (and (stringp sid) (> (length sid) 8)) (subseq sid 0 8) sid))

(defun %minutes-ago (ts)
  (max 0 (round (- (get-universal-time) ts) 60)))

(defun %recent-task-slugs (db &optional (limit 5))
  (mapcar #'first (sqlite:execute-to-list db
                    "SELECT slug FROM tasks ORDER BY updated_ts DESC LIMIT ?" limit)))

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

(defun %swarm-readout (db me task-slug &key (window-minutes 60) (limit 20))
  "Each other session's latest activity within the window: its session, the task
it last touched, the event type, and minutes since. Sessions last active on
TASK-SLUG are flagged as concurrent work. ME, when non-NIL, is excluded."
  (let* ((cutoff (- (get-universal-time) (* window-minutes 60)))
         (rows (sqlite:execute-to-list db
                 "SELECT e.session_id, e.task_id, e.type, e.ts
                    FROM events e
                    JOIN (SELECT session_id, MAX(seq) AS max_seq
                            FROM events
                           WHERE session_id IS NOT NULL AND ts >= ?
                           GROUP BY session_id) m
                      ON e.session_id = m.session_id AND e.seq = m.max_seq
                   WHERE (? IS NULL OR e.session_id <> ?)
                   ORDER BY e.ts DESC
                   LIMIT ?"
                 cutoff me me limit)))
    (with-output-to-string (out)
      (if (null rows)
          (format out "  swarm: no other sessions active in the last ~Dm~%" window-minutes)
          (progn
            (format out "  swarm (~D active, last ~Dm):~%" (length rows) window-minutes)
            (dolist (r rows)
              (destructuring-bind (sid stask type ts) r
                (format out "    ~A on ~A — ~A ~Dm ago~A~%"
                        (%session-abbrev sid) (or stask "?") type (%minutes-ago ts)
                        (if (and task-slug stask (string= stask task-slug))
                            " (also on this task)" "")))))))))

(defun run-task-bootstrap (tool parameters context &key call-id on-update)
  "One-call orientation on a task: computed state, neighbors, open handoffs,
recent observations, and a readout of what other sessions are doing. Adopts the
task as current only when no current task is set; never overrides an existing
pointer, and records no event."
  (declare (ignore tool call-id on-update))
  (let ((target (or (%bare-slug (tool-parameter parameters :task_id))
                    (current-task-id context))))
    (if (null target)
        (%fail "No task to bootstrap; pass task_id or select a task first.")
        (with-cairn-store-lock (context)
          (let* ((db (context-db context))
                 (state (%task-get-text db target)))
            (if (null state)
                (%fail "No task ~A.~@[ Recent: ~{~A~^, ~}~]"
                       target (%recent-task-slugs db))
                (progn
                  (unless (current-task-id context)
                    (setf (current-task-id context) target))
                  (%text
                   (with-output-to-string (out)
                     (write-string state out)
                     (let ((h (%open-handoffs-text db target)))
                       (when h (write-string h out)))
                     (write-string
                      (%swarm-readout db (current-session-id context) target)
                      out))))))))))

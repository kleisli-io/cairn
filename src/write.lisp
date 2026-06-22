(in-package #:kli/cairn)

;;; The single write boundary: append one event to the log and fold it into the
;;; materialized projection in one transaction. Projections are a pure function
;;; of the events log, so `rebuild` reconstructs them from `events` alone.

;;; --- ULID: time-sortable stable identity ---

(defparameter +crockford+ "0123456789ABCDEFGHJKMNPQRSTVWXYZ")

(defun %bytes->int (bytes)
  (let ((n 0))
    (loop for b across bytes do (setf n (logior (ash n 8) b)))
    n))

(defun encode-crockford (int width)
  "Big-endian Crockford base32 of INT in exactly WIDTH characters."
  (let ((s (make-string width)))
    (loop for i from (1- width) downto 0 do
      (setf (char s i) (char +crockford+ (logand int 31))
            int (ash int -5)))
    s))

(defun make-ulid ()
  "A 26-char ULID: 48-bit millisecond time + 80-bit randomness, lexicographically
time-sortable."
  (let ((ms (* (- (get-universal-time) 2208988800) 1000))
        (rnd (%bytes->int (ironclad:random-data 10))))
    (concatenate 'string (encode-crockford ms 10) (encode-crockford rnd 16))))

;;; --- Canonical encodings ---

(defun canonical-ts (raw)
  "Canonical CL universal-time. Integers above ~3e9 are already universal-time;
smaller integers are Unix epoch seconds and are shifted. NIL means now."
  (cond
    ((null raw) (get-universal-time))
    ((integerp raw) (if (> raw 3000000000) raw (+ raw 2208988800)))
    (t (error "Non-integer timestamp ~S is not supported." raw))))

(defun split-depot (slug)
  "Split a possibly depot-qualified SLUG at its first colon into
(values depot bare). DEPOT is NIL when SLUG carries no prefix."
  (let ((pos (and slug (position #\: slug))))
    (if pos
        (values (subseq slug 0 pos) (subseq slug (1+ pos)))
        (values nil slug))))

(defun %json-write-string (s out)
  (write-char #\" out)
  (loop for ch across s do
    (case ch
      (#\" (write-string "\\\"" out))
      (#\\ (write-string "\\\\" out))
      (#\Newline (write-string "\\n" out))
      (#\Return (write-string "\\r" out))
      (#\Tab (write-string "\\t" out))
      (t (if (< (char-code ch) #x20)
             (format out "\\u~4,'0X" (char-code ch))
             (write-char ch out)))))
  (write-char #\" out))

(defun %plist-like-p (x)
  "True when X is a non-empty even-length list keyed entirely by keywords."
  (and (consp x)
       (evenp (length x))
       (loop for k in x by #'cddr always (keywordp k))))

(defun %json-key-name (k) (string-downcase (symbol-name k)))

(defun %canon-value (v out)
  (cond
    ((null v) (write-string "null" out))
    ((eq v t) (write-string "true" out))
    ((stringp v) (%json-write-string v out))
    ((integerp v) (princ v out))
    ((floatp v) (format out "~F" v))
    ((keywordp v) (%json-write-string (%json-key-name v) out))
    ((symbolp v) (%json-write-string (string-downcase (symbol-name v)) out))
    ((%plist-like-p v) (%canon-object v out))
    ((listp v) (%canon-array v out))
    (t (%json-write-string (princ-to-string v) out))))

(defun %canon-array (list out)
  (write-char #\[ out)
  (loop for (x . rest) on list do
    (%canon-value x out)
    (when rest (write-char #\, out)))
  (write-char #\] out))

(defun %canon-object (plist out)
  (let ((pairs (sort (loop for (k v) on plist by #'cddr
                           collect (cons (%json-key-name k) v))
                     #'string< :key #'car)))
    (write-char #\{ out)
    (loop for (pair . rest) on pairs do
      (%json-write-string (car pair) out)
      (write-char #\: out)
      (%canon-value (cdr pair) out)
      (when rest (write-char #\, out)))
    (write-char #\} out)))

(defun canonical-json (data)
  "Deterministic JSON for the plist DATA, key-sorted recursively so the encoding
is invariant to plist key order. NIL encodes as the empty object."
  (with-output-to-string (out)
    (if (null data) (write-string "{}" out) (%canon-object data out))))

(defun %json->lisp (x)
  "Convert a jzon parse result back into the plist/list/atom shape the reducer
reads. Object keys become upcased keywords; JSON null becomes NIL."
  (cond
    ((hash-table-p x)
     (let ((plist '()))
       (maphash (lambda (k v)
                  (push (intern (string-upcase k) :keyword) plist)
                  (push (%json->lisp v) plist))
                x)
       (nreverse plist)))
    ((and (vectorp x) (not (stringp x))) (map 'list #'%json->lisp x))
    ((eq x t) t)
    ((symbolp x) nil)
    (t x)))

(defun event-key (task-id type ts session data)
  "Content address of an event: lower-hex SHA-256 over its identifying fields,
the dedup key behind INSERT OR IGNORE."
  (ironclad:byte-array-to-hex-string
   (ironclad:digest-sequence
    :sha256
    (sb-ext:string-to-octets
     (format nil "~A~C~A~C~D~C~A~C~A"
             (or task-id "") #\Nul type #\Nul ts #\Nul
             (or session "") #\Nul (canonical-json data))
     :external-format :utf-8))))

;;; --- Event record (replay carrier) ---

(defstruct (cairn-event (:constructor %make-cairn-event) (:conc-name cev-))
  (seq 0 :read-only t)
  (event-id nil :read-only t)
  (event-key nil :read-only t)
  (task-id nil :read-only t)        ; slug as stored in events.task_id
  (type "" :read-only t)
  (ts 0 :read-only t)
  (session-id nil :read-only t)
  (prev-session-id nil :read-only t)
  (data nil :read-only t))          ; payload plist

(defun %row->event (row)
  (destructuring-bind (seq event-id event-key task-id type ts session prev data) row
    (%make-cairn-event :seq seq :event-id event-id :event-key event-key
                       :task-id task-id :type type :ts ts
                       :session-id session :prev-session-id prev
                       :data (%json->lisp (com.inuoe.jzon:parse data)))))

;;; --- Projection helpers ---

(defun %task-id (db slug)
  (sqlite:execute-single db "SELECT id FROM tasks WHERE slug = ?" slug))

(defun %ensure-task (db slug depot ts)
  "Return the id of the tasks row for SLUG, minting a skeletal row when absent."
  (or (%task-id db slug)
      (progn
        (sqlite:execute-non-query db
          "INSERT INTO tasks(slug, depot, created_ts, updated_ts) VALUES(?,?,?,?)"
          slug depot ts ts)
        (sqlite:last-insert-rowid db))))

(defun %lww-status (db task-id status ts)
  "Set STATUS only when this event's TS is at least the stored status_ts. Applied
in seq order, this yields last-writer-by-(ts,seq) wins."
  (sqlite:execute-non-query db
    "UPDATE tasks SET status = ?, status_ts = ?, updated_ts = MAX(updated_ts, ?)
      WHERE id = ? AND (status_ts IS NULL OR ? >= status_ts)"
    status ts ts task-id ts))

(defun %set-description (db task-id description ts)
  "Set DESCRIPTION only when this event's TS is at least the stored
description_ts, making description an LWW-register like %lww-status. Applied in
(ts, event_id) order this yields last-writer-wins; the guard keeps an
incremental out-of-order write from clobbering a newer one."
  (sqlite:execute-non-query db
    "UPDATE tasks SET description = ?, description_ts = ?, updated_ts = MAX(updated_ts, ?)
      WHERE id = ? AND (description_ts IS NULL OR ? >= description_ts)"
    (or description "") ts ts task-id ts))

(defun %set-project (db task-id project-id)
  "Stamp PROJECT-ID on the task when given; never clears an existing id."
  (when (and (stringp project-id) (plusp (length project-id)))
    (sqlite:execute-non-query db
      "UPDATE tasks SET project_id = ? WHERE id = ?" project-id task-id)))

(defun %set-parent (db child-id parent-id ts)
  (when (and child-id parent-id (/= child-id parent-id))
    (sqlite:execute-non-query db
      "UPDATE tasks SET parent_task_id = ?, updated_ts = MAX(updated_ts, ?) WHERE id = ?"
      parent-id ts child-id)))

(defun %upsert-edge (db src dst type tag ts)
  "Insert a lateral edge, idempotent on (src,dst,type,tag); self-loops are no-ops."
  (when (and src dst (/= src dst))
    (sqlite:execute-non-query db
      "INSERT OR IGNORE INTO edges(src_id, dst_id, type, tag, created_ts)
       VALUES(?,?,?,?,?)"
      src dst type tag ts)))

(defun %sever (db emitter-id target-raw raw-type)
  "Remove the relation EMITTER names to TARGET. Structural types clear the
parent FK on whichever side holds it; lateral types delete the edge row."
  (multiple-value-bind (depot bare) (split-depot target-raw)
    (declare (ignore depot))
    (let ((target-id (%task-id db bare))
          (type (and raw-type (string-downcase raw-type))))
      (when target-id
        (if (structural-edge-type-p type)
            (progn
              (sqlite:execute-non-query db
                "UPDATE tasks SET parent_task_id = NULL WHERE id = ? AND parent_task_id = ?"
                emitter-id target-id)
              (sqlite:execute-non-query db
                "UPDATE tasks SET parent_task_id = NULL WHERE id = ? AND parent_task_id = ?"
                target-id emitter-id))
            (multiple-value-bind (etype tag) (normalize-edge-type type)
              (declare (ignore tag))
              (sqlite:execute-non-query db
                "DELETE FROM edges WHERE src_id = ? AND dst_id = ? AND type = ?"
                emitter-id target-id etype)))))))

;;; --- The reducer: one arm per retained event type ---

(defun apply-event-to-projection (db event emitter-id)
  "Fold EVENT into the projection. EMITTER-ID is the tasks.id of the event's own
task. Unknown types are left in the log and ignored here (forward-compatible)."
  (let ((type (cev-type event))
        (data (cev-data event))
        (ts (cev-ts event))
        (eid (cev-event-id event)))
    (flet ((d (k) (getf data k))
           (ensure-other (raw)
             (multiple-value-bind (depot bare) (split-depot raw)
               (%ensure-task db bare depot ts))))
      (cond
        ((string= type "task.create")
         (%set-description db emitter-id (d :description) ts)
         (%set-project db emitter-id (d :project-id))
         (%lww-status db emitter-id "active" ts))

        ((string= type "task.update-status")
         (let ((s (d :status)))
           (when s (%lww-status db emitter-id (validate-status s) ts))))

        ((string= type "task.update-description")
         (%set-description db emitter-id (d :description) ts))

        ((or (string= type "task.fork") (string= type "task.spawn"))
         (let ((et (and (d :edge-type) (string-downcase (d :edge-type))))
               (child (ensure-other (d :child-id))))
           (if (structural-edge-type-p (or et "phase-of"))
               (%set-parent db child emitter-id ts)
               (multiple-value-bind (etype tag) (normalize-edge-type et)
                 (%upsert-edge db emitter-id child etype tag ts)))))

        ((string= type "task.link")
         (let ((et (and (d :edge-type) (string-downcase (d :edge-type))))
               (target (ensure-other (d :target-id))))
           (if (structural-edge-type-p et)
               (%set-parent db emitter-id target ts)
               (multiple-value-bind (etype tag) (normalize-edge-type et)
                 (%upsert-edge db emitter-id target etype tag ts)))))

        ((string= type "task.sever")
         (%sever db emitter-id (d :target-id) (d :edge-type)))

        ((string= type "task.reclassify")
         (%sever db emitter-id (d :target-id) (d :old-type))
         (let ((et (and (d :new-type) (string-downcase (d :new-type))))
               (target (ensure-other (d :target-id))))
           (if (structural-edge-type-p et)
               (%set-parent db emitter-id target ts)
               (multiple-value-bind (etype tag) (normalize-edge-type et)
                 (%upsert-edge db emitter-id target etype tag ts)))))

        ((string= type "task.set-metadata")
         (sqlite:execute-non-query db
           "INSERT INTO task_metadata(task_id, key, value, ts) VALUES(?,?,?,?)
            ON CONFLICT(task_id, key) DO UPDATE SET value = excluded.value, ts = excluded.ts
              WHERE excluded.ts >= task_metadata.ts"
           emitter-id (d :key) (d :value) ts))

        ((string= type "observation")
         (let ((text (d :text)))
           (when text
             (sqlite:execute-non-query db
               "INSERT OR IGNORE INTO observations(event_id, task_id, text, ts)
                VALUES(?,?,?,?)"
               eid emitter-id (sb-unicode:normalize-string text :nfc) ts))))

        ((string= type "handoff.create")
         (sqlite:execute-non-query db
           "INSERT INTO handoffs(event_id, task_id, path, summary, ts) VALUES(?,?,?,?,?)"
           eid emitter-id (d :path) (or (d :summary) "") ts)
         (sqlite:execute-non-query db
           "INSERT INTO observations(event_id, task_id, text, ts) VALUES(NULL,?,?,?)"
           emitter-id
           (sb-unicode:normalize-string
            (format nil "Handoff: ~A → ~A" (or (d :summary) "") (d :path)) :nfc)
           ts))

        ((string= type "artifact.create")
         (sqlite:execute-non-query db
           "INSERT OR IGNORE INTO artifacts(task_id, path, kind, ts) VALUES(?,?,?,?)"
           emitter-id (d :path) (d :kind) ts))

        ((string= type "artifact.delete")
         (sqlite:execute-non-query db
           "DELETE FROM artifacts WHERE task_id = ? AND path = ?"
           emitter-id (d :path)))

        ;; View vocabulary keys on the view name, not the emitter: a definition
        ;; is global, recorded under the reserved @cairn node only so it rides
        ;; the one event spine. The ts guards make define/undefine last-writer-
        ;; wins and fold-order-independent.
        ((string= type "view.define")
         (sqlite:execute-non-query db
           "INSERT INTO named_views(name, query, ts) VALUES(?,?,?)
            ON CONFLICT(name) DO UPDATE SET query = excluded.query, ts = excluded.ts
              WHERE excluded.ts >= named_views.ts"
           (d :name) (d :query) ts))

        ((string= type "view.undefine")
         (sqlite:execute-non-query db
           "DELETE FROM named_views WHERE name = ? AND ? >= ts"
           (d :name) ts))

        (t nil)))))

;;; --- The write boundary ---

(defun %prev-session (db task-slug session)
  "The continuation link for SESSION's next write to TASK-SLUG: the most recent
distinct session to have written the task, or NIL when there is no handover. A
deterministic function of the seq-ordered log, so a rebuild reproduces it and an
import populates it without a live host."
  (when session
    (let ((last (sqlite:execute-single db
                  "SELECT session_id FROM events
                    WHERE task_id = ? AND session_id IS NOT NULL
                    ORDER BY seq DESC LIMIT 1"
                  task-slug)))
      (and last (not (string= last session)) last))))

(defvar *mirror-log-p* t
  "When NIL, record-event folds an event without mirroring it to the log. Bound
NIL while replaying the log into the cache, so an ingested line is not re-appended.")

(defun %store-file (db)
  "The on-disk path of DB's main database, or NIL for a store with no file."
  (let ((file (third (first (sqlite:execute-to-list db "PRAGMA database_list")))))
    (and (stringp file) (plusp (length file)) file)))

(defun %append-to-log (db slug line)
  "Append LINE to SLUG's event log beside the store file, creating the task
directory on first write. A no-op when the store has no backing file."
  (let ((file (%store-file db)))
    (when file
      (let ((path (cairn-task-log-under (uiop:pathname-directory-pathname file) slug)))
        (ensure-directories-exist path)
        (with-open-file (out path :direction :output
                                  :if-exists :append :if-does-not-exist :create
                                  :external-format :utf-8)
          (write-string line out)
          (write-char #\Newline out))))))

(defun record-event (db task-slug type payload
                     &key session prev-session raw-ts event-id legacy-id source-seq
                          imported-at)
  "Append one event, fold it into the projection in one transaction, and mirror
it to the per-task log on a non-duplicate append. DB is a raw store handle.
PREV-SESSION overrides the derived continuation link; EVENT-ID supplies a stable
id when replaying or importing, keeping the (ts, event_id) fold order portable
across stores. Returns the new events.seq, or NIL when the event duplicated an
existing one (same content key) and was ignored."
  (let* ((ts (canonical-ts raw-ts))
         (eid (or event-id (make-ulid))))
    (multiple-value-bind (depot bare) (split-depot task-slug)
      (let ((ekey (event-key bare type ts session payload))
            (seq nil)
            (line nil))
        (sqlite:with-transaction db
          (let ((prev (or prev-session (%prev-session db task-slug session))))
            (sqlite:execute-non-query db
              "INSERT OR IGNORE INTO events
                 (event_key, event_id, task_id, type, ts, session_id, prev_session_id,
                  data, legacy_id, source_seq, imported_at)
               VALUES (?,?,?,?,?,?,?,?,?,?,?)"
              ekey eid task-slug type ts session prev
              (canonical-json payload) legacy-id source-seq imported-at)
            (when (plusp (sqlite:execute-single db "SELECT changes()"))
              (setf seq (sqlite:last-insert-rowid db))
              (let ((emitter (and bare (%ensure-task db bare depot ts))))
                (when emitter
                  (apply-event-to-projection
                   db
                   (%make-cairn-event :seq seq :event-id eid :event-key ekey
                                      :task-id task-slug :type type :ts ts
                                      :session-id session :prev-session-id prev
                                      :data payload)
                   emitter)
                  (setf line
                        (event->line
                         (list :event-id eid :event-key ekey :task-id task-slug
                               :type type :ts ts :session-id session
                               :prev-session-id prev :data payload
                               :legacy-id legacy-id :source-seq source-seq
                               :imported-at imported-at))))))))
        ;; Mirror only after the projection commits, so a rolled-back fold never
        ;; leaves the log — the source of truth — ahead of the store.
        (when (and line *mirror-log-p*) (%append-to-log db bare line))
        seq))))

;;; --- Rebuild / repair ---

(defun %fold-row (db row)
  (let ((event (%row->event row)))
    (multiple-value-bind (depot bare) (split-depot (cev-task-id event))
      (when bare
        (apply-event-to-projection
         db event (%ensure-task db bare depot (cev-ts event)))))))

(defun rebuild (db &key (transaction t))
  "Delete every materialized projection and re-fold the whole log in portable
(ts, event_id) order, independent of the local seq. The projection is a
deterministic function of the event multiset, so this reconstructs it exactly
and identically on any store that holds the same events."
  (flet ((body ()
           (dolist (tbl '("edges" "observations" "handoffs" "task_metadata"
                          "artifacts" "named_views"))
             (sqlite:execute-non-query db (format nil "DELETE FROM ~A" tbl)))
           (sqlite:execute-non-query db "DELETE FROM tasks")
           (dolist (row (sqlite:execute-to-list db
                          "SELECT seq, event_id, event_key, task_id, type, ts,
                                  session_id, prev_session_id, data
                             FROM events ORDER BY ts, event_id"))
             (%fold-row db row))
           (sqlite:execute-non-query db "INSERT INTO obs_fts(obs_fts) VALUES('rebuild')")))
    (if transaction (sqlite:with-transaction db (body)) (body))
    db))

(defun rebuild-fts (db)
  "Rebuild only the full-text index from the observations content table."
  (sqlite:execute-non-query db "INSERT INTO obs_fts(obs_fts) VALUES('rebuild')")
  db)

(defun %projection-digest (db)
  "A content hash of the projections, excluding volatile surrogate keys, so a
clean replay of an unchanged log digests identically."
  (let ((out (make-string-output-stream)))
    (dolist (q '("SELECT id,slug,depot,parent_task_id,prev_phase_id,status,description,created_ts,updated_ts,status_ts,description_ts,project_id FROM tasks ORDER BY id"
                 "SELECT src_id,dst_id,type,IFNULL(tag,'') FROM edges ORDER BY src_id,dst_id,type,IFNULL(tag,'')"
                 "SELECT task_id,text,ts FROM observations ORDER BY obs_id"
                 "SELECT task_id,path,summary,ts FROM handoffs ORDER BY id"
                 "SELECT task_id,key,value,ts FROM task_metadata ORDER BY task_id,key"
                 "SELECT task_id,path,kind,ts FROM artifacts ORDER BY id"
                 "SELECT name,query,ts FROM named_views ORDER BY name"))
      (write-line q out)
      (dolist (row (sqlite:execute-to-list db q))
        (prin1 row out)
        (terpri out)))
    (ironclad:byte-array-to-hex-string
     (ironclad:digest-sequence
      :sha256
      (sb-ext:string-to-octets (get-output-stream-string out) :external-format :utf-8)))))

(defun verify (db)
  "Replay the log over the live projection inside a rolled-back savepoint and
confirm the result matches the current projection. Non-mutating; returns T when
the projection is a faithful fold of the log."
  (let ((live (%projection-digest db)))
    (sqlite:execute-non-query db "SAVEPOINT cairn_verify")
    (unwind-protect
         (progn
           (rebuild db :transaction nil)
           (string= live (%projection-digest db)))
      (sqlite:execute-non-query db "ROLLBACK TO cairn_verify")
      (sqlite:execute-non-query db "RELEASE cairn_verify"))))

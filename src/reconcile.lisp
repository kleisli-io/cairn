(in-package #:kli/cairn)

;;; Store-open reconcile: the per-task log is the source of truth, the cache a
;;; rebuildable view. On open we union the two — ingest log lines the cache
;;; lacks, export cache rows the log lacks (the crash gap between a committed row
;;; and a mirror append that never landed) — then re-fold in portable order. A
;;; per-task watermark (a single (mtime, size) stat) in schema_meta skips a file
;;; that has not moved, so an unchanged store reconciles to a no-op.
;;;
;;; A running store also refreshes between opens: `reconcile-if-stale` reads one
;;; shared epoch counter — bumped by every append — and sweeps only when it has
;;; moved, so an idle store spends O(1) per call and never re-stats a log.

(defun %task-log-files (dir)
  "Every tasks/<slug>/events.ndjson under DIR."
  (directory (make-pathname :directory (append (pathname-directory dir)
                                               (list "tasks" :wild))
                            :name "events" :type "ndjson" :defaults dir)))

(defun %log-slug (path)
  "The bare slug naming PATH's task directory."
  (car (last (pathname-directory path))))

(defun %read-locked-lines (path)
  "Every line of PATH read under a shared flock, or NIL when PATH is absent. The
lock waits out an in-flight exclusive append, so no partial line is observed."
  (when (probe-file path)
    (with-open-file (in path :external-format :utf-8)
      (with-file-lock (in +lock-sh+)
        (loop for line = (read-line in nil nil) while line collect line)))))

(defun %file-watermark (path)
  "PATH's freshness watermark \"<mtime>:<size>\" from a single stat, or NIL when
PATH is absent. A moved watermark is enough to decide a log must be re-read; an
append always grows the size, so a same-second write can never hide behind the
mtime. Ingest is idempotent on event_key, so an over-eager re-read costs only the
reread, never a duplicate — cheaper than hashing every byte on every open."
  (when (probe-file path)
    (let ((st (sb-posix:stat path)))
      (format nil "~D:~D" (sb-posix:stat-mtime st) (sb-posix:stat-size st)))))

(defun %watermark-key (slug) (concatenate 'string "log-watermark:" slug))

(defun %read-watermark (db slug)
  (sqlite:execute-single db "SELECT value FROM schema_meta WHERE key = ?"
                         (%watermark-key slug)))

(defun %write-watermark (db slug value)
  (when value
    (sqlite:execute-non-query db
      "INSERT INTO schema_meta(key, value) VALUES(?,?)
       ON CONFLICT(key) DO UPDATE SET value = excluded.value"
      (%watermark-key slug) value)))

(defun %current-epoch (dir)
  "The shared epoch counter under DIR, or 0 when the marker is absent. A single
small read under a shared lock — O(1) regardless of how many task logs exist."
  (let ((path (cairn-epoch-under dir)))
    (if (probe-file path)
        (with-open-file (in path :external-format :utf-8)
          (with-file-lock (in +lock-sh+)
            (or (ignore-errors
                 (parse-integer (read-line in nil "") :junk-allowed t))
                0)))
        0)))

(defparameter +epoch-meta-key+ "reconcile-epoch"
  "schema_meta key holding the epoch this store last swept to.")

(defun %read-seen-epoch (db)
  "The epoch this store recorded at its last sweep, or NIL when it has never
swept."
  (let ((v (sqlite:execute-single db "SELECT value FROM schema_meta WHERE key = ?"
                                  +epoch-meta-key+)))
    (and v (ignore-errors (parse-integer v)))))

(defun %write-seen-epoch (db value)
  (sqlite:execute-non-query db
    "INSERT INTO schema_meta(key, value) VALUES(?,?)
     ON CONFLICT(key) DO UPDATE SET value = excluded.value"
    +epoch-meta-key+ (princ-to-string value)))

(defun %file-event-keys (path)
  "The set of event_key strings the log at PATH already carries."
  (let ((keys (make-hash-table :test 'equal)))
    (dolist (line (%read-locked-lines path))
      (let ((key (getf (line->event-fields line) :event-key)))
        (when key (setf (gethash key keys) t))))
    keys))

(defun %replay-line (db line)
  "Fold one decoded LINE into DB, carrying its identity and provenance. Returns
the new seq, or NIL when the event already existed (INSERT OR IGNORE)."
  (let ((f (line->event-fields line)))
    (record-event db (getf f :task-id) (getf f :type) (getf f :data)
                  :raw-ts (getf f :ts)
                  :session (getf f :session-id)
                  :prev-session (getf f :prev-session-id)
                  :event-id (getf f :event-id)
                  :legacy-id (getf f :legacy-id)
                  :source-seq (getf f :source-seq)
                  :imported-at (getf f :imported-at))))

(defun ingest-task-log (db path)
  "Replay every line of the log at PATH into DB, skipping events it already
holds. Returns T when at least one new event entered the cache."
  (let ((new nil))
    (dolist (line (%read-locked-lines path) new)
      (when (plusp (length (string-trim '(#\Space #\Tab #\Return #\Newline) line)))
        (when (%replay-line db line) (setf new t))))))

(defun ingest-logs (db dir)
  "Ingest every task log under DIR whose watermark has moved, advancing each read
log's watermark so an unchanged log is skipped on the next pass — the freshness
gate that keeps a live store's repeated sweeps cheap. The watermark stamped is
the one read before the ingest, so an append that lands mid-read stays ahead of
it and is picked up next time. Returns T when any new event entered the cache
(the caller then re-folds)."
  (let ((changed nil))
    (dolist (path (%task-log-files dir) changed)
      (let* ((slug (%log-slug path))
             (wm (%file-watermark path)))
        (unless (equal wm (%read-watermark db slug))
          (when (ingest-task-log db path) (setf changed t))
          (%write-watermark db slug wm))))))

(defun export-unlogged-events (db dir)
  "Append to each task's log the events the cache holds but the file lacks — the
crash gap between a committed row and a mirror append that never landed."
  (let ((groups (make-hash-table :test 'equal)))
    (dolist (row (sqlite:execute-to-list db
                   "SELECT event_id, event_key, task_id, type, ts, session_id,
                           prev_session_id, data, legacy_id, source_seq, imported_at
                      FROM events ORDER BY ts, event_id"))
      (destructuring-bind (eid ekey tid type ts session prev data legacy sseq iat) row
        (multiple-value-bind (depot bare) (split-depot tid)
          (declare (ignore depot))
          (when bare
            (push (list :event-id eid :event-key ekey :task-id tid :type type :ts ts
                        :session-id session :prev-session-id prev
                        :data (%json->lisp (com.inuoe.jzon:parse data))
                        :legacy-id legacy :source-seq sseq :imported-at iat)
                  (gethash bare groups))))))
    (maphash
     (lambda (bare rows)
       (let ((have (%file-event-keys (cairn-task-log-under dir bare))))
         (dolist (fields (nreverse rows))
           (unless (gethash (getf fields :event-key) have)
             (%append-to-log db bare (event->line fields))))))
     groups)))

(defun refresh-watermarks (db dir)
  "Stamp the current watermark of every task log under DIR, so the next open sees
an unchanged store and skips both directions."
  (dolist (path (%task-log-files dir))
    (%write-watermark db (%log-slug path) (%file-watermark path))))

(defun reconcile-store (db)
  "Union the per-task logs and the cache at store-open: ingest log lines the
cache lacks (re-folding in portable order when any arrive), export cache rows the
logs lack, then refresh every watermark to a no-op steady state and record the
epoch swept to. The export runs unconditionally — a crash gap is precisely the
case where the missing append never bumped the epoch — so it is not epoch-gated.
A no-op when the store has no backing file."
  (let ((file (%store-file db)))
    (when file
      (let ((dir (uiop:pathname-directory-pathname file)))
        (when (let ((*mirror-log-p* nil)) (ingest-logs db dir))
          (rebuild db))
        (export-unlogged-events db dir)
        (refresh-watermarks db dir)
        (%write-seen-epoch db (%current-epoch dir))))))

(defun reconcile-if-stale (db)
  "Refresh a live store between opens: when the shared epoch has not moved since
the last sweep, an O(1) no-op; otherwise ingest the logs whose stat has moved and
re-fold. The read counterpart to the append's epoch bump — a running session
picks up a peer's writes on its next call without re-reading an unchanged log.
Ingest-only: crash-gap export belongs to store-open, not the hot path. A no-op
when the store has no backing file."
  (let ((file (%store-file db)))
    (when file
      (let* ((dir (uiop:pathname-directory-pathname file))
             (epoch (%current-epoch dir)))
        (unless (eql epoch (%read-seen-epoch db))
          (when (let ((*mirror-log-p* nil)) (ingest-logs db dir))
            (rebuild db))
          ;; Record the epoch read before the sweep: a bump that lands mid-sweep
          ;; leaves the counter ahead of this value, so the next call re-sweeps
          ;; and never misses it.
          (%write-seen-epoch db epoch))))))

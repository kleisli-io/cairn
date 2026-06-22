(in-package #:kli/cairn)

;;; Store-open reconcile: the per-task log is the source of truth, the cache a
;;; rebuildable view. On open we union the two — ingest log lines the cache
;;; lacks, export cache rows the log lacks (the crash gap between a committed row
;;; and a mirror append that never landed) — then re-fold in portable order. A
;;; per-task watermark (content hash + byte length) in schema_meta skips a file
;;; that has not moved, so an unchanged store reconciles to a no-op.

(defun %task-log-files (dir)
  "Every tasks/<slug>/events.ndjson under DIR."
  (directory (make-pathname :directory (append (pathname-directory dir)
                                               (list "tasks" :wild))
                            :name "events" :type "ndjson" :defaults dir)))

(defun %log-slug (path)
  "The bare slug naming PATH's task directory."
  (car (last (pathname-directory path))))

(defun %file-watermark (path)
  "PATH's watermark \"<sha256-hex>:<byte-length>\", or NIL when PATH is absent."
  (when (probe-file path)
    (with-open-file (in path :element-type '(unsigned-byte 8))
      (let* ((len (file-length in))
             (buf (make-array len :element-type '(unsigned-byte 8))))
        (read-sequence buf in)
        (format nil "~A:~D"
                (ironclad:byte-array-to-hex-string
                 (ironclad:digest-sequence :sha256 buf))
                len)))))

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

(defun %file-event-keys (path)
  "The set of event_key strings the log at PATH already carries."
  (let ((keys (make-hash-table :test 'equal)))
    (when (probe-file path)
      (dolist (line (uiop:read-file-lines path))
        (let ((key (getf (line->event-fields line) :event-key)))
          (when key (setf (gethash key keys) t)))))
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
    (dolist (line (uiop:read-file-lines path) new)
      (when (plusp (length (string-trim '(#\Space #\Tab #\Return #\Newline) line)))
        (when (%replay-line db line) (setf new t))))))

(defun ingest-logs (db dir)
  "Ingest every task log under DIR whose watermark has moved. Returns T when any
new event entered the cache (the caller then re-folds)."
  (let ((changed nil))
    (dolist (path (%task-log-files dir) changed)
      (let ((slug (%log-slug path)))
        (unless (equal (%file-watermark path) (%read-watermark db slug))
          (when (ingest-task-log db path) (setf changed t)))))))

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
logs lack, then refresh every watermark to a no-op steady state. A no-op when the
store has no backing file."
  (let ((file (%store-file db)))
    (when file
      (let ((dir (uiop:pathname-directory-pathname file)))
        (when (let ((*mirror-log-p* nil)) (ingest-logs db dir))
          (rebuild db))
        (export-unlogged-events db dir)
        (refresh-watermarks db dir)))))

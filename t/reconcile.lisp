(in-package #:kli/cairn/tests)
(in-suite all)

;;; Store-open reconcile unions the per-task log and the cache. The log is the
;;; source of truth: losing the cache and reopening replays the log to the same
;;; projection; a foreign line appended by another writer is folded in; a cache
;;; row whose mirror append never landed is exported back to the log; and an
;;; unchanged store reconciles to a no-op, never growing the log.

(defun %append-raw-line (logpath line)
  "Append LINE to LOGPATH as another writer would, outside the store."
  (with-open-file (out logpath :direction :output
                               :if-exists :append :if-does-not-exist :create
                               :external-format :utf-8)
    (write-string line out)
    (write-char #\Newline out)))

(defun %store-log-path (db slug)
  (cairn::cairn-task-log-under
   (uiop:pathname-directory-pathname (cairn::%store-file db)) slug))

(test reconcile-rebuilds-the-cache-from-the-log-after-cache-loss
  "Deleting the cache and reopening replays the per-task logs into an identical
projection."
  (let* ((dir (make-test-dir (temp-root) "rc"))
         (path (namestring (merge-pathnames "cairn.db" dir)))
         (db (cairn:open-cairn-store path)))
    (cairn:record-event db "alpha" "task.create" '(:description "a") :raw-ts 3990200000)
    (cairn:record-event db "alpha" "observation" '(:text "note a") :raw-ts 3990200001)
    (cairn:record-event db "beta" "task.create" '(:description "b") :raw-ts 3990200002)
    (cairn:record-event db "alpha" "task.update-status" '(:status "completed")
                        :raw-ts 3990200003)
    (let ((before (cairn::%projection-digest db)))
      (cairn:close-cairn-store db)
      (dolist (suffix '("" "-wal" "-shm"))
        (uiop:delete-file-if-exists (concatenate 'string path suffix)))
      (let ((db2 (cairn:open-cairn-store path)))
        (unwind-protect
             (progn
               (is (zerop (sqlite:execute-single db2 "SELECT count(*) FROM events"))
                   "the reopened cache starts empty")
               (cairn::reconcile-store db2)
               (is (string= before (cairn::%projection-digest db2))
                   "replaying the logs reproduces the projection digest")
               (is (cairn:verify db2) "the rebuilt cache folds its own log"))
          (cairn:close-cairn-store db2))))))

(test reconcile-ingests-a-foreign-appended-line
  "A line appended to a task's log by another writer is folded into the cache on
the next reconcile, and ingest never re-appends what it read."
  (let* ((dir (make-test-dir (temp-root) "rc"))
         (path (namestring (merge-pathnames "cairn.db" dir)))
         (db (cairn:open-cairn-store path)))
    (unwind-protect
         (progn
           (cairn:record-event db "t" "task.create" '(:description "d") :raw-ts 3990210000)
           (cairn::reconcile-store db)
           (let ((line (cairn::event->line
                        (list :event-id (concatenate 'string (make-string 25 :initial-element #\0) "F")
                              :event-key (cairn::event-key "t" "observation" 3990210005 nil
                                                           '(:text "foreign"))
                              :task-id "t" :type "observation" :ts 3990210005
                              :session-id nil :prev-session-id nil
                              :data '(:text "foreign")))))
             (%append-raw-line (%store-log-path db "t") line))
           (cairn::reconcile-store db)
           (is (= 1 (sqlite:execute-single db
                      "SELECT count(*) FROM observations WHERE text = 'foreign'"))
               "the foreign observation is folded into the cache")
           (is (= 2 (length (%log-lines db "t")))
               "ingest does not re-append the line it read")
           (is (cairn:verify db) "the cache still folds its log"))
      (cairn:close-cairn-store db))))

(test reconcile-exports-a-crash-gap-event
  "An event committed to the cache whose mirror append never landed is written
back to the log on reconcile, and a clean reconcile after is a no-op."
  (let* ((dir (make-test-dir (temp-root) "rc"))
         (path (namestring (merge-pathnames "cairn.db" dir)))
         (db (cairn:open-cairn-store path)))
    (unwind-protect
         (progn
           (cairn:record-event db "t" "task.create" '(:description "d") :raw-ts 3990220000)
           (cairn::reconcile-store db)
           (is (= 1 (length (%log-lines db "t"))) "the log holds the create")
           (let ((cairn::*mirror-log-p* nil))
             (cairn:record-event db "t" "observation" '(:text "gap") :raw-ts 3990220005))
           (is (= 1 (length (%log-lines db "t"))) "the gap event missed the log")
           (cairn::reconcile-store db)
           (let ((lines (%log-lines db "t")))
             (is (= 2 (length lines)) "reconcile exports the gap event to the log")
             (is (some (lambda (l)
                         (string= "gap" (getf (getf (cairn::line->event-fields l) :data)
                                              :text)))
                       lines)
                 "the exported line carries the gap observation"))
           (cairn::reconcile-store db)
           (is (= 2 (length (%log-lines db "t"))) "a reconciled store is a no-op"))
      (cairn:close-cairn-store db))))

(test reconcile-on-an-unchanged-store-is-a-no-op
  "Repeated reconciles of an unchanged store ingest nothing, export nothing, and
leave the log byte-for-byte the same."
  (let* ((dir (make-test-dir (temp-root) "rc"))
         (path (namestring (merge-pathnames "cairn.db" dir)))
         (db (cairn:open-cairn-store path)))
    (unwind-protect
         (progn
           (cairn:record-event db "t" "task.create" '(:description "d") :raw-ts 3990230000)
           (cairn:record-event db "t" "observation" '(:text "n") :raw-ts 3990230001)
           (cairn::reconcile-store db)
           (let ((digest (cairn::%projection-digest db))
                 (lines (%log-lines db "t")))
             (dotimes (i 3) (cairn::reconcile-store db))
             (is (equal lines (%log-lines db "t"))
                 "the log bytes are unchanged across reconciles")
             (is (string= digest (cairn::%projection-digest db))
                 "the projection is unchanged")))
      (cairn:close-cairn-store db))))

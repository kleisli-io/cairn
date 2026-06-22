(in-package #:kli/cairn/tests)
(in-suite all)

;;; record-event mirrors every newly-appended event to the per-task log beside
;;; the store: one canonical-JSON line per event. The task directory is created
;;; on the first event; a duplicate event appends nothing; a task seen only as a
;;; reference target gets no log.

(defun %log-lines (db slug)
  "The lines of SLUG's event log beside DB, or NIL when the log is absent."
  (let* ((file (cairn::%store-file db))
         (path (cairn::cairn-task-log-under
                (uiop:pathname-directory-pathname file) slug)))
    (when (probe-file path) (uiop:read-file-lines path))))

(test write-mirror-appends-one-line-per-new-event
  "Each durable append writes one decodable line to the task's log."
  (with-event-store (db)
    (cairn:record-event db "t" "task.create" '(:description "d") :raw-ts 3990100000)
    (cairn:record-event db "t" "observation" '(:text "note") :raw-ts 3990100001)
    (let ((lines (%log-lines db "t")))
      (is (= 2 (length lines)) "two events, two lines")
      (let ((f (cairn::line->event-fields (first lines))))
        (is (string= "task.create" (getf f :type)))
        (is (string= "t" (getf f :task-id)))
        (is (string= "d" (getf (getf f :data) :description)))))))

(test write-mirror-line-matches-the-stored-event
  "The mirrored line carries the same event_id the store recorded."
  (with-event-store (db)
    (cairn:record-event db "t" "observation" '(:text "x")
                        :raw-ts 3990100000 :event-id "01J000000000000000000000ID")
    (let ((f (cairn::line->event-fields (first (%log-lines db "t")))))
      (is (string= "01J000000000000000000000ID" (getf f :event-id))
          "the log preserves the stable event_id")
      (is (string= (sqlite:execute-single db
                     "SELECT event_key FROM events WHERE task_id = 't'")
                   (getf f :event-key))
          "the log carries the store's content key"))))

(test write-mirror-skips-duplicate-events
  "A duplicate content key is ignored by the store and appends no second line."
  (with-event-store (db)
    (cairn:record-event db "t" "task.create" '(:description "d") :raw-ts 3990100000)
    (cairn:record-event db "t" "task.create" '(:description "d") :raw-ts 3990100000)
    (is (= 1 (length (%log-lines db "t"))) "the re-applied event adds no line")))

(test write-mirror-creates-the-log-dir-on-the-first-event
  "The task directory materializes on the first event, before any handoff or
artifact is written."
  (with-event-store (db)
    (cairn:record-event db "fresh" "task.create" '() :raw-ts 3990100000)
    (let ((dir (uiop:pathname-directory-pathname
                (cairn::cairn-task-log-under
                 (uiop:pathname-directory-pathname (cairn::%store-file db))
                 "fresh"))))
      (is (uiop:directory-exists-p dir) "tasks/fresh/ exists after the first event"))))

(test write-mirror-leaves-reference-only-tasks-without-a-log
  "A task minted only as a link target, with no event of its own, gets no log."
  (with-event-store (db)
    (cairn:record-event db "parent" "task.create" '() :raw-ts 3990100000)
    (cairn:record-event db "parent" "task.link"
                        '(:target-id "ghost" :edge-type "related") :raw-ts 3990100001)
    (is (%log-lines db "parent") "the emitting task has a log")
    (is (null (%log-lines db "ghost"))
        "the reference-only target has no log directory")))

(test write-mirror-depot-qualified-event-logs-under-the-bare-slug
  "An event recorded under a depot-qualified slug logs beside its bare-slug
scratchpad, while the line keeps the qualified task_id."
  (with-event-store (db)
    (cairn:record-event db "dep:work" "task.create" '() :raw-ts 3990100000)
    (let ((lines (%log-lines db "work")))
      (is (= 1 (length lines)) "the log lives under the bare slug")
      (is (string= "dep:work"
                   (getf (cairn::line->event-fields (first lines)) :task-id))
          "the line preserves the depot-qualified task_id"))))

(in-package #:kli/cairn/tests)
(in-suite all)

;;; The per-task log is union-merged in git: two sides' appends combine into one
;;; file with duplicates and no ordering guarantee. Because the fold is deduped
;;; (event_key) and order-independent ((ts, event_id)), reconciling that union
;;; reproduces the projection of the deduped set folded canonically.

(defun %merge-line (eid type ts data)
  "One canonical-JSON log line for task t, its event_key derived as the store
would derive it."
  (cairn::event->line
   (list :event-id eid :event-key (cairn::event-key "t" type ts nil data)
         :task-id "t" :type type :ts ts :session-id nil :prev-session-id nil
         :data data)))

(test ensure-log-gitattributes-writes-the-union-rule-once
  "The store directory gets a single union-merge rule for the per-task logs,
re-running leaves it unchanged."
  (let* ((dir (make-test-dir (temp-root) "ga"))
         (path (namestring (merge-pathnames "cairn.db" dir)))
         (attrs (merge-pathnames ".gitattributes" dir)))
    (cairn:ensure-log-gitattributes path)
    (cairn:ensure-log-gitattributes path)
    (is (= 1 (count "tasks/**/events.ndjson merge=union"
                    (uiop:read-file-lines attrs) :test #'string=))
        "the union rule is present exactly once")))

(test union-merged-log-converges-to-the-canonical-fold
  "A union-merged log — shared prefix, divergent tails, one duplicated line —
reconciles to the same projection as the deduped event set folded in canonical
(ts, event_id) order."
  (let* ((dir (make-test-dir (temp-root) "mc"))
         (path (namestring (merge-pathnames "cairn.db" dir)))
         (prefix (list (%merge-line "E1" "task.create" 3990300000 '(:description "init"))
                       (%merge-line "E2" "task.update-description" 3990300010
                                    '(:description "shared"))))
         (dup (%merge-line "ED" "observation" 3990300015 '(:text "dup")))
         (a-tail (list (%merge-line "EA" "task.update-description" 3990300030
                                    '(:description "from-a"))
                       dup))
         (b-tail (list (%merge-line "EB" "observation" 3990300020 '(:text "from-b"))
                       dup))
         (union (append prefix a-tail b-tail)))
    (let ((logpath (merge-pathnames "tasks/t/events.ndjson" dir)))
      (ensure-directories-exist logpath)
      (with-open-file (out logpath :direction :output :if-exists :supersede
                                   :if-does-not-exist :create :external-format :utf-8)
        (dolist (l union) (write-string l out) (write-char #\Newline out))))
    (let ((db (cairn:open-cairn-store path)))
      (unwind-protect
           (progn
             (cairn::reconcile-store db)
             (is (cairn:verify db) "the reconciled cache folds its merged log")
             (is (= 1 (sqlite:execute-single db
                        "SELECT count(*) FROM observations WHERE text = 'dup'"))
                 "the duplicated line collapses to a single event")
             (is (string= "from-a"
                          (sqlite:execute-single db
                            "SELECT description FROM tasks WHERE slug = 't'"))
                 "the higher-ts description wins after the union")
             (let ((digest (cairn::%projection-digest db)))
               (with-event-store (ref)
                 (cairn:record-event ref "t" "task.create" '(:description "init")
                                     :raw-ts 3990300000 :event-id "E1")
                 (cairn:record-event ref "t" "task.update-description" '(:description "shared")
                                     :raw-ts 3990300010 :event-id "E2")
                 (cairn:record-event ref "t" "observation" '(:text "dup")
                                     :raw-ts 3990300015 :event-id "ED")
                 (cairn:record-event ref "t" "observation" '(:text "from-b")
                                     :raw-ts 3990300020 :event-id "EB")
                 (cairn:record-event ref "t" "task.update-description" '(:description "from-a")
                                     :raw-ts 3990300030 :event-id "EA")
                 (cairn:rebuild ref)
                 (is (string= digest (cairn::%projection-digest ref))
                     "the merged log digests identically to the canonical fold"))))
        (cairn:close-cairn-store db)))))

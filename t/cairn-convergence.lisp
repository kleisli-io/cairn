(in-package #:kli/cairn/tests)
(in-suite all)

;;; The projection is a deterministic fold of the event multiset, ordered by
;;; (ts, event_id). These tests prove union-merge of divergent logs converges,
;;; description is an LWW-register, and same-ts events tie-break by event_id.

(defun apply-specs (db specs)
  "Apply each spec (SLUG TYPE PAYLOAD &key TS EVENT-ID SESSION) to DB in order."
  (dolist (s specs)
    (destructuring-bind (slug type payload &key ts event-id session) s
      (cairn:record-event db slug type payload
                          :raw-ts ts :event-id event-id :session session))))

(defun rebuilt-digest (db)
  "Rebuild DB's projection from its log and return the projection digest."
  (cairn:rebuild db)
  (cairn::%projection-digest db))

(test description-is-an-lww-register
  "Description is last-writer-by-ts: a later-ts update wins even when an
earlier-ts update is recorded afterward, and verify confirms the fold."
  (with-event-store (db)
    (cairn:record-event db "t" "task.create" '(:description "v1") :raw-ts 3990000100)
    (cairn:record-event db "t" "task.update-description" '(:description "v3") :raw-ts 3990000300)
    (cairn:record-event db "t" "task.update-description" '(:description "v2") :raw-ts 3990000200)
    (is (string= "v3"
                 (sqlite:execute-single db "SELECT description FROM tasks WHERE slug = 't'"))
        "the highest-ts description wins regardless of record order")
    (is (cairn:verify db) "the incremental projection equals the ordered fold")))

(test verify-holds-under-out-of-ts-order-updates
  "With the task created first, status and description updates recorded out of
ts order still leave the live projection equal to the ordered fold."
  (with-event-store (db)
    (cairn:record-event db "t" "task.create" '(:description "d0") :raw-ts 3990000100)
    (cairn:record-event db "t" "task.update-status" '(:status "completed") :raw-ts 3990000400)
    (cairn:record-event db "t" "task.update-description" '(:description "d2") :raw-ts 3990000500)
    (cairn:record-event db "t" "task.update-status" '(:status "active") :raw-ts 3990000200)
    (cairn:record-event db "t" "task.update-description" '(:description "d1") :raw-ts 3990000300)
    (is (cairn:verify db) "the incremental projection equals the ordered fold")
    (is (string= "completed"
                 (sqlite:execute-single db "SELECT status FROM tasks WHERE slug = 't'"))
        "status is the ts=400 completed, not the later-recorded ts=200 active")
    (is (string= "d2"
                 (sqlite:execute-single db "SELECT description FROM tasks WHERE slug = 't'"))
        "description is the ts=500 d2, not the later-recorded ts=300 d1")))

(test union-multiset-is-order-independent
  "Two divergent event sets unioned in either interleaving rebuild to the same
projection digest: the fold depends only on the multiset, not the order."
  (let ((set-a '(("shared" "task.create" (:description "init") :ts 3990010010)
                 ("shared" "task.update-description" (:description "from-a") :ts 3990010050)
                 ("a-only" "task.create" (:description "a") :ts 3990010030)))
        (set-b '(("shared" "task.update-description" (:description "from-b") :ts 3990010040)
                 ("shared" "observation" (:text "b watched shared") :ts 3990010060)
                 ("b-only" "task.create" (:description "b") :ts 3990010020))))
    (with-event-store (db1)
      (with-event-store (db2)
        (apply-specs db1 (append set-a set-b))
        (apply-specs db2 (append set-b set-a))
        (is (string= (rebuilt-digest db1) (rebuilt-digest db2))
            "union converges under both interleavings")
        (is (string= "from-a"
                     (sqlite:execute-single db1
                       "SELECT description FROM tasks WHERE slug = 'shared'"))
            "the ts=50 from-a beats the ts=40 from-b")))))

(test same-ts-events-tie-break-by-event-id
  "Events sharing a ts are ordered by event_id, so two stores that ingest the
same events in opposite order converge once event_id is stable."
  (let* ((base (make-string 25 :initial-element #\0))
         (e1 (concatenate 'string base "A"))
         (e2 (concatenate 'string base "B")))
    (with-event-store (db1)
      (with-event-store (db2)
        (cairn:record-event db1 "t" "task.create" '() :raw-ts 3990020000)
        (cairn:record-event db1 "t" "observation" '(:text "first by id")
                            :raw-ts 3990020005 :event-id e1)
        (cairn:record-event db1 "t" "observation" '(:text "second by id")
                            :raw-ts 3990020005 :event-id e2)
        (cairn:record-event db2 "t" "task.create" '() :raw-ts 3990020000)
        (cairn:record-event db2 "t" "observation" '(:text "second by id")
                            :raw-ts 3990020005 :event-id e2)
        (cairn:record-event db2 "t" "observation" '(:text "first by id")
                            :raw-ts 3990020005 :event-id e1)
        (is (string= (rebuilt-digest db1) (rebuilt-digest db2))
            "same-ts events tie-break deterministically by event_id")))))

(test duplicate-event-key-collapses-in-union
  "Re-applying an identical event set folds to the same projection: event_key
dedup makes the union idempotent."
  (let ((specs '(("t" "task.create" (:description "d") :ts 3990030000)
                 ("t" "observation" (:text "note") :ts 3990030001)
                 ("t" "task.update-status" (:status "completed") :ts 3990030002))))
    (with-event-store (db1)
      (with-event-store (db2)
        (apply-specs db1 specs)
        (apply-specs db2 (append specs specs))
        (is (= 1 (sqlite:execute-single db2 "SELECT count(*) FROM observations"))
            "the duplicated observation collapses to one row")
        (is (string= (rebuilt-digest db1) (rebuilt-digest db2))
            "the union with duplicates digests identically to the deduped set")))))

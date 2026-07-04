(in-package #:kli/cairn/tests)
(in-suite all)

(test session-id-comes-from-the-host-binding
  "current-session-id reads the host's bound session; the sole bound mode needs
no mode-id."
  (let* ((context (kli:make-kernel-host))
         (service (make-instance 'session:agent-session :id :agent-session-service)))
    (kli:register-live-object (kli:context-registry context) service)
    (setf (gethash :main (session:session-mode-bindings service))
          (session:make-mode-binding
           :mode-id :main
           :session-binding (make-instance 'session:agent-session-binding
                                            :session-id :sess-7)))
    (is (string= "SESS-7" (cairn:current-session-id context :main)))
    (is (string= "SESS-7" (cairn:current-session-id context)))))

(test a-write-needs-no-session-and-no-bus
  "With no agent session service the id is NULL, and a record lands in SQLite
with no event bus or protocol present at all."
  (let ((context (kli:make-kernel-host)))
    (is (null (cairn:current-session-id context))))
  (with-event-store (db)
    (cairn:record-event db "solo" "task.create" '() :raw-ts 3990000000)
    (is (= 1 (sqlite:execute-single db "SELECT count(*) FROM events")))
    (is (null (sqlite:execute-single db
                "SELECT session_id FROM events WHERE task_id = 'solo'"))
        "an absent session records as NULL")))

(test continuation-links-the-prior-session-on-a-handover
  "prev_session_id marks a session handover for a task and is NULL within a
session; the clock column stays inert."
  (with-event-store (db)
    (cairn:record-event db "T" "task.create" '() :session "s-a" :raw-ts 3990000000)
    (cairn:record-event db "T" "observation" '(:text "a1") :session "s-a" :raw-ts 3990000001)
    (cairn:record-event db "T" "observation" '(:text "b1") :session "s-b" :raw-ts 3990000002)
    (cairn:record-event db "T" "observation" '(:text "b2") :session "s-b" :raw-ts 3990000003)
    (flet ((prev (text)
             (sqlite:execute-single db
               "SELECT prev_session_id FROM events
                 WHERE type = 'observation' AND json_extract(data, '$.text') = ?"
               text)))
      (is (null (prev "a1")) "no handover within the opening session")
      (is (string= "s-a" (prev "b1")) "the next session's first event links back")
      (is (null (prev "b2")) "same-session events do not relink"))
    (is (string= "{}" (sqlite:execute-single db
                        "SELECT DISTINCT vector_clock FROM events"))
        "the clock stays inert")))

(test an-explicit-prev-session-overrides-derivation
  "An imported continuation link is honored over the derived one."
  (with-event-store (db)
    (cairn:record-event db "T" "task.create" '() :session "s-x"
                        :prev-session "imported-parent" :raw-ts 3990000000)
    (is (string= "imported-parent"
                 (sqlite:execute-single db
                   "SELECT prev_session_id FROM events WHERE task_id = 'T'")))))

(in-package #:kli/cairn/tests)
(in-suite all)

;;; The live per-turn context block and its headless guards. The agent-session
;;; stack is too heavy for this harness, so the recode plumbing is exercised
;;; only through its no-service guard; the pure render is tested over the store.

(test extra-messages-is-nil-without-a-current-task
  "With no current task the per-turn injection contributes nothing."
  (with-cairn-protocol (context protocol)
    (declare (ignore protocol))
    (is (null (cairn::cairn-extra-messages context)))))

(test render-names-the-task-and-its-recent-observation
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create (list :name "the live context task") context)
    (let ((slug (cairn:current-task-id context)))
      (ext:invoke-tool protocol :observe (list :text "the canary note") context)
      (let ((text (cairn::render-task-context (task-db protocol) slug nil)))
        (is (search "Current task" text) "the block is headed")
        (is (search slug text) "the block names the task")
        (is (search "canary" text) "the block carries the recent observation")))))

(test render-flags-a-concurrent-peer-session
  "A peer session active on the same task surfaces a swarm conflict line."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create (list :name "the shared context task") context)
    (let ((slug (cairn:current-task-id context))
          (db (task-db protocol)))
      (cairn:record-event db slug "observation"
                          (list :text "peer note on the shared task")
                          :session "SESSIONPEER01")
      (let ((text (cairn::render-task-context db slug nil)))
        (is (search "swarm" text) "the block carries a swarm note")
        (is (search "other session" text) "the note names the concurrent work")))))

(test render-budgets-itself
  "An over-budget render is truncated with a marker."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create (list :name "the budgeted context task") context)
    (let ((slug (cairn:current-task-id context)))
      (let ((text (cairn::render-task-context (task-db protocol) slug nil :budget 50)))
        (is (search "(truncated)" text) "the render stops at the budget")))))

(test install-context-is-a-no-op-without-an-agent-session
  "With no agent-session service present the context effect installs nothing."
  (with-cairn-protocol (context protocol)
    (is (null (cairn::install-cairn-context protocol nil context)))))

(in-package #:kli/cairn/tests)
(in-suite all)

(test handoff-scaffolds-a-file-and-records-the-path
  "The handoff tool mints a path under the task scratchpad, writes a skeleton,
and records the path on the handoffs row."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create (list :name "the handoff scaffold task") context)
    (let* ((slug (cairn:current-task-id context))
           (result (ext:invoke-tool protocol :handoff
                                    (list :summary "scaffold the resumable handoff") context)))
      (is (not (ext:tool-result-error-p result)))
      (let ((path (sqlite:execute-single (task-db protocol)
                    "SELECT h.path FROM handoffs h JOIN tasks t ON h.task_id = t.id
                      WHERE t.slug = ?" slug)))
        (is (and (stringp path) (plusp (length path))) "a path was minted")
        (is (probe-file path) "the skeleton file exists on disk")
        (is (search slug (uiop:read-file-string path)) "the skeleton names the task")))))

(test bootstrap-orients-and-adopts-only-when-none-is-set
  "task_bootstrap returns the task state and adopts the task as current when no
pointer is set."
  (with-cairn-protocol (context protocol)
    (let ((slug (created-slug
                 (ext:invoke-tool protocol :task_create
                                  (list :name "the bootstrap adopt task") context))))
      (setf (cairn:current-task-id context) nil)
      (let ((result (ext:invoke-tool protocol :task_bootstrap (list :task_id slug) context)))
        (is (not (ext:tool-result-error-p result)))
        (is (string= slug (cairn:current-task-id context)) "adopted as the current task")
        (is (search slug (tool-text result)) "the readout names the task")
        (is (search "swarm" (tool-text result)) "the readout carries a swarm section")))))

(test bootstrap-does-not-override-an-existing-pointer
  "When a current task is already set, bootstrapping another task reads it without
moving the pointer."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create (list :name "the first current task") context)
    (let ((current (cairn:current-task-id context))
          (other (created-slug
                  (ext:invoke-tool protocol :task_create
                                   (list :name "some other existing task") context))))
      (is (string= current (cairn:current-task-id context)) "the second create did not adopt")
      (let ((result (ext:invoke-tool protocol :task_bootstrap (list :task_id other) context)))
        (is (search other (tool-text result)) "the readout names the bootstrapped task")
        (is (string= current (cairn:current-task-id context))
            "the human-set pointer is left alone")))))

(test bootstrap-swarm-shows-other-sessions-and-flags-the-shared-task
  "The swarm readout names other sessions' latest activity and flags those last
active on the bootstrapped task."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create (list :name "the swarm focus task") context)
    (let ((slug (cairn:current-task-id context))
          (db (task-db protocol)))
      (cairn:record-event db slug "observation"
                          (list :text "peer note on the shared task")
                          :session "SESSIONPEER01")
      (cairn:record-event db "2026-06-18-a-different-peer-task" "observation"
                          (list :text "peer note elsewhere")
                          :session "SESSIONFARAWAY")
      (let ((text (tool-text (ext:invoke-tool protocol :task_bootstrap '() context))))
        (is (search "SESSIONP" text) "names the peer on the shared task")
        (is (search "also on this task" text) "flags the concurrent session")
        (is (search "SESSIONF" text) "names the session working elsewhere")))))

(test bootstrap-errors-on-an-unknown-task
  (with-cairn-protocol (context protocol)
    (is (ext:tool-result-error-p
         (ext:invoke-tool protocol :task_bootstrap
                          (list :task_id "2026-01-01-no-such-task-anywhere") context)))))

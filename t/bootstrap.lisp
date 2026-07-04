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
        (is (search slug (tool-text result)) "the readout names the task")))))

(test bootstrap-with-explicit-task-id-switches-the-pointer
  "An explicit task_id focuses that task: bootstrapping it makes it current even
when another task is already current. A subsequent no-arg bootstrap orients on the
now-current task and leaves the pointer alone."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create (list :name "the first current task") context)
    (let ((current (cairn:current-task-id context))
          (other (created-slug
                  (ext:invoke-tool protocol :task_create
                                   (list :name "some other existing task") context))))
      (is (string= current (cairn:current-task-id context)) "the second create did not adopt")
      (let ((result (ext:invoke-tool protocol :task_bootstrap (list :task_id other) context)))
        (is (search other (tool-text result)) "the readout names the bootstrapped task")
        (is (string= other (cairn:current-task-id context))
            "an explicit task_id switches the pointer"))
      (let ((result (ext:invoke-tool protocol :task_bootstrap '() context)))
        (is (search other (tool-text result)) "a no-arg bootstrap orients on the current task")
        (is (string= other (cairn:current-task-id context))
            "a no-arg bootstrap leaves the pointer alone")))))

(test bootstrap-includes-the-earlier-observations-pointer
  "task_bootstrap inherits the capped-observations pointer through %task-get-text:
past the shown five it names N earlier, full=true, and types=observation."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create (list :name "the bootstrap cap task") context)
    (dotimes (i 8)
      (ext:invoke-tool protocol :observe (list :text (format nil "boot note ~D" i)) context))
    (let ((out (tool-text (ext:invoke-tool protocol :task_bootstrap '() context))))
      (is (search "3 earlier observation" out) "bootstrap shows the pointer with the right N")
      (is (search "full=true" out) "the pointer names the full flag")
      (is (search "types=observation" out) "the pointer names the observation type"))))

(test bootstrap-errors-on-an-unknown-task
  "An unknown task_id fails and leaves the current pointer untouched -- the switch
happens only once the task is found."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create (list :name "the standing current task") context)
    (let ((current (cairn:current-task-id context)))
      (is (ext:tool-result-error-p
           (ext:invoke-tool protocol :task_bootstrap
                            (list :task_id "2026-01-01-no-such-task-anywhere") context)))
      (is (string= current (cairn:current-task-id context))
          "a failed bootstrap does not move the pointer"))))

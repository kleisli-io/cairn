(in-package #:kli/cairn/tests)
(in-suite all)

;;; Slash commands over the store. The commands provider installs before cairn
;;; so cairn's register effect finds it. The agent-session stack is absent here,
;;; so /handoff and /resume are exercised through their headless guards.

(defmacro with-cairn-commands-protocol ((context-var protocol-var cairn-var) &body body)
  "Like WITH-CAIRN-PROTOCOL but with the commands provider installed before cairn,
so the command-registration effect has a provider to register against."
  (let ((root (gensym "ROOT")))
    `(let* ((,root (temp-root))
            (,context-var (kli:make-kernel-host))
            (,protocol-var (switch-to-extension-protocol ,context-var)))
       (let ((config:*global-config-dir* (make-test-dir ,root "global"))
             (config:*project-start-directory* (make-test-dir ,root "proj"))
             (cairn:*cairn-db-path*
               (merge-pathnames "cairn.db" (make-test-dir ,root "db"))))
         (install-extension ,context-var obj:*standard-object-extension-manifest*)
         (install-extension ,context-var event:*events-extension-manifest*)
         (install-extension ,context-var config:*config-extension-manifest*)
         (install-extension ,context-var commands:*commands-extension-manifest*)
         (let ((,cairn-var
                 (install-extension ,context-var cairn:*cairn-extension-manifest*)))
           (declare (ignorable ,cairn-var))
           (with-cairn-tool-authority ,@body))))))

(defparameter +cairn-command-names+
  '("observe" "handoff" "task" "tasks" "resume"))

(defun commands-provider (protocol)
  (ext:find-capability-provider protocol :commands :contract :commands/v1))

(defun registered-command-names (protocol)
  (mapcar #'commands:command-name
          (ext:provider-call (commands-provider protocol) :list-commands)))

(defun command-text (result)
  "The concatenated text of a command result's content."
  (with-output-to-string (out)
    (dolist (item (commands:command-result-content result))
      (write-string (getf item :text "") out))))

(defun invoke-cairn-command (protocol name arguments context)
  (ext:provider-call (commands-provider protocol) :invoke-command name arguments context))

(test commands-register-against-the-provider
  "Activating cairn registers all five slash commands on the commands provider."
  (with-cairn-commands-protocol (context protocol cairn)
    (declare (ignore context cairn))
    (let ((names (registered-command-names protocol)))
      (dolist (name +cairn-command-names+)
        (is (member name names :test #'string=) "~A is registered" name)))))

(test observe-command-records-on-the-current-task
  "/observe delegates to the observe tool and records on the current task."
  (with-cairn-commands-protocol (context protocol cairn)
    (declare (ignore cairn))
    (ext:invoke-tool protocol :task_create (list :name "the observe command task") context)
    (let ((slug (cairn:current-task-id context)))
      (let ((result (invoke-cairn-command protocol :observe
                                          (list :tail "a note via the command") context)))
        (is (not (commands:command-result-error-p result))))
      (is (= 1 (obs-count protocol slug)) "the note is recorded"))))

(test task-command-selects-a-task-by-id
  "/task <id> moves the per-protocol pointer to a named task."
  (with-cairn-commands-protocol (context protocol cairn)
    (declare (ignore cairn))
    (ext:invoke-tool protocol :task_create (list :name "the first command task") context)
    (let ((first (cairn:current-task-id context))
          (other (created-slug
                  (ext:invoke-tool protocol :task_create
                                   (list :name "another command task") context))))
      (is (string= first (cairn:current-task-id context)) "the second create did not adopt")
      (invoke-cairn-command protocol :task (list :tail other) context)
      (is (string= other (cairn:current-task-id context)) "/task selected the named task"))))

(test tasks-command-lists-recent-tasks
  "/tasks with no argument lists recent tasks."
  (with-cairn-commands-protocol (context protocol cairn)
    (declare (ignore cairn))
    (ext:invoke-tool protocol :task_create (list :name "the listed command task") context)
    (let ((slug (cairn:current-task-id context)))
      (let ((text (command-text (invoke-cairn-command protocol :tasks '() context))))
        (is (search slug text) "the recent listing names the active task")))))

(test handoff-and-resume-degrade-without-an-interactive-session
  "/handoff and /resume reply without error when no agent session is present;
/resume still selects a task and records a resume event."
  (with-cairn-commands-protocol (context protocol cairn)
    (declare (ignore cairn))
    (ext:invoke-tool protocol :task_create (list :name "the headless ritual task") context)
    (let ((slug (cairn:current-task-id context)))
      (let ((handoff (invoke-cairn-command protocol :handoff
                                           (list :tail "some guidance") context)))
        (is (not (commands:command-result-error-p handoff)))
        (is (search "interactive session" (command-text handoff))
            "/handoff degrades without a session"))
      (let ((resume (invoke-cairn-command protocol :resume '() context)))
        (is (not (commands:command-result-error-p resume)) "/resume replies without error")
        (is (search "Resumed" (command-text resume)) "/resume selected the task")
        (is (string= slug (cairn:current-task-id context)) "the pointer is on the resumed task")))))

(test deactivating-cairn-unregisters-its-commands
  "Deactivating cairn retracts its commands from the provider."
  (with-cairn-commands-protocol (context protocol cairn)
    (is (= (length +cairn-command-names+)
           (length (intersection +cairn-command-names+ (registered-command-names protocol)
                                  :test #'string=)))
        "all commands are present before deactivation")
    (with-extension-load-authority
      (ext:deactivate-extension protocol cairn context))
    (let ((names (registered-command-names protocol)))
      (dolist (name +cairn-command-names+)
        (is (not (member name names :test #'string=))
            "~A is gone after deactivation" name)))))

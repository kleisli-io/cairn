(in-package #:kli/cairn)

;;; Human-facing slash commands that manipulate cairn state directly. Prompt
;;; templates such as handoff.md and workon.md are registered by the prompts
;;; extension from the resource root, so they are not duplicated here.

(defun %command-fail (format &rest args)
  (make-command-result
   :content (list (make-command-text-content (apply #'format nil format args)))
   :error-p t))

(defun %command-from-tool (result)
  (make-command-result
   :content (tool-result-content result)
   :details (tool-result-details result)
   :error-p (tool-result-error-p result)))

(defun run-cairn-observe-command (command arguments context &key call-id on-update)
  (declare (ignore command))
  (let ((text (rest-arg arguments)))
    (if (null text)
        (%command-fail "Usage: /observe <text>")
        (%command-from-tool
         (invoke-tool (active-protocol context) :observe (list :text text) context
                      :call-id call-id :on-update on-update)))))


(defun run-cairn-task-command (command arguments context &key call-id on-update)
  (declare (ignore command call-id on-update))
  (let ((id (%bare-slug (rest-arg arguments))))
    (with-cairn-store-lock (context)
      (let ((db (context-db context)))
        (cond
          (id (let ((state (%task-get-text db id)))
                (if state
                    (progn (setf (current-task-id context) id)
                           (reply (format nil "Current task set to ~A.~%~A" id state)))
                    (reply (format nil "No task ~A.~@[ Recent: ~{~A~^, ~}~]"
                                   id (%recent-task-slugs db))))))
          (t (let ((cur (current-task-id context)))
               (if (null cur)
                   (reply (format nil "No current task.~@[ Recent: ~{~A~^, ~}~]"
                                  (%recent-task-slugs db)))
                   (reply (or (%task-get-text db cur)
                              (format nil "No task ~A." cur)))))))))))

(defun run-cairn-tasks-command (command arguments context &key call-id on-update)
  (declare (ignore command call-id on-update))
  (let ((raw (rest-arg arguments)))
    (with-cairn-store-lock (context)
      (let ((*query-db* (context-db context))
            (*query-current* (current-task-id context)))
        (handler-case
            (reply (format-query-result
                    (if raw (interpret-query (safe-read-query raw))
                        (run-named-query "recent"))))
          (cairn-query-parse-error (c)
            (%command-fail "Parse error: ~A" (cairn-query-error-message c)))
          (cairn-query-error (c)
            (%command-fail "Query error: ~A" (cairn-query-error-message c)))
          (sqlite:sqlite-error ()
            (%command-fail "The query could not be executed.")))))))


(defun run-cairn-where-command (command arguments context &key call-id on-update)
  (declare (ignore command arguments call-id on-update))
  (multiple-value-bind (path step) (resolve-cairn-db-location context)
    (let* ((project (resolve-project context))
           (scratch (string= (cp-project-id project) +scratch-project-id+)))
      (reply (format nil "Database: ~A~%Resolved by: ~A~%Project: ~A (~A)~%Source: ~A~:[~;~%Scratch: yes~]"
                     (namestring path)
                     (string-downcase (symbol-name step))
                     (cp-project-id project) (cp-display-name project)
                     (cp-source project) scratch)))))

(defun cairn-command-specs ()
  "(name label description arguments runner metadata) per command."
  (list
   (list :observe "Observe" "Record an observation on the current task."
         '(:tail :text) #'run-cairn-observe-command nil)
   (list :task "Task" "Show the current task, or select one by id."
         '(:tail :id) #'run-cairn-task-command '(:model-visible nil))
   (list :tasks "Tasks" "List recent tasks, or run a task-graph query."
         '(:tail :query) #'run-cairn-tasks-command '(:model-visible nil))
   (list :where "Where" "Show the resolved database path, project, and how it was resolved."
         nil #'run-cairn-where-command '(:model-visible nil))))

(defun register-cairn-commands (protocol contribution context)
  (declare (ignore protocol))
  (let ((commands (find-capability-provider (active-protocol context)
                                            :commands :contract :commands/v1))
        (source (contribution-extension contribution)))
    (when commands
      (loop for (name label description arguments runner metadata)
              in (cairn-command-specs)
            collect (provider-call commands :register-command context name
                                   (make-command :name name :label label
                                                 :description description
                                                 :arguments arguments :runner runner
                                                 :metadata metadata)
                                   :source source)))))

(defun unregister-cairn-commands (protocol contribution context)
  (declare (ignore protocol))
  (let ((commands (find-capability-provider (active-protocol context)
                                            :commands :contract :commands/v1)))
    (when commands
      (dolist (registration (contribution-state contribution))
        (provider-call commands :unregister-command context registration)))))

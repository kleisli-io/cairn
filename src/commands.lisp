(in-package #:kli/cairn)

;;; Human-facing slash commands. /observe and /handoff are model-visible; the
;;; selection and listing commands hide their echo from the model. The effect
;;; self-guards: with no commands provider (headless) it registers nothing.

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

(defparameter +cairn-handoff-authoring-prompt+
  "Write a handoff for the current task so another session can resume cleanly —
thorough yet concise: compact the context without losing key details.

First compose a concise one-line summary of where things stand. Call the handoff
tool with that summary to scaffold the document; it returns a path and records the
handoff. Read the scaffolded file, then overwrite it with a rich handoff using this
structure:

  Frontmatter: date, git_branch, git_commit, repository, task, type: handoff,
  status: active.

  # Handoff: <task> — <brief description>

  ## Task(s) — the work and the status of each item; if on a phased plan, call out
  the current phase.

  ## Critical References — the 2-3 must-read paths for the next session.

  ## Recent Changes — changes made, in file:line form.

  ## Learnings — what was discovered, each with file:line evidence.

  ## Artifacts — everything produced or updated, as paths or file:line references.

  ## Task Graph State — if the task has phases: current phase, completed phases,
  pending phases, and related tasks, from task_query(\"plan\").

  ## Action Items & Next Steps — a numbered list of what to do next.

  ## Other Notes — anything else worth carrying over.

Prefer file:line references over long code blocks, and cross-reference research.md
and plan.md when they exist.~@[ Guidance: ~A~]")

(defun run-cairn-handoff-command (command arguments context &key call-id on-update)
  (declare (ignore command call-id on-update))
  (let ((service (find-live-object (context-registry context) :agent-session-service)))
    (if (null service)
        (reply "Handoff authoring needs an interactive session.")
        (let ((mode-id (or (getf arguments :mode-id) :default-mode)))
          (follow-up-agent-session
           service mode-id
           (format nil +cairn-handoff-authoring-prompt+ (rest-arg arguments))
           context)
          (reply "Composing a handoff...")))))

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

(defun %resume-block (db slug)
  (with-output-to-string (out)
    (format out "Following the cairns - resuming ~A.~%~%" slug)
    (let ((state (%task-get-text db slug))) (when state (write-string state out)))
    (let ((h (%open-handoffs-text db slug))) (when h (write-string h out)))))

(defun %inject-resume-block (context arguments text)
  "Write TEXT into the durable transcript as a one-shot context patch. No-op
headless or when no agent-context is bound."
  (let ((service (find-live-object (context-registry context) :agent-session-service)))
    (when service
      (let ((agent-context (agent-session-context
                            service (or (getf arguments :mode-id) :default-mode) context)))
        (when agent-context
          (stage-context-patch agent-context
                               (make-append-message-patch (make-user-message text)))
          (commit-context-patches agent-context context))))))

(defun run-cairn-resume-command (command arguments context &key call-id on-update)
  (declare (ignore command call-id on-update))
  (let ((resume-text nil) (message nil))
    (with-cairn-store-lock (context)
      (let* ((db (context-db context))
             (slug (or (%bare-slug (rest-arg arguments))
                       (first (%recent-task-slugs db 1)))))
        (cond
          ((null slug) (setf message "No task to resume."))
          ((null (%task-get-text db slug))
           (setf message (format nil "No task ~A.~@[ Recent: ~{~A~^, ~}~]"
                                 slug (%recent-task-slugs db))))
          (t (setf (current-task-id context) slug)
             (%record context slug "resume" nil)
             (setf resume-text (%resume-block db slug)
                   message (format nil "Resumed ~A." slug))))))
    (when resume-text (%inject-resume-block context arguments resume-text))
    (reply message)))

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
   (list :handoff "Handoff" "Compose and record a resumable handoff for the current task."
         '(:tail :guidance) #'run-cairn-handoff-command nil)
   (list :task "Task" "Show the current task, or select one by id."
         '(:tail :id) #'run-cairn-task-command '(:model-visible nil))
   (list :tasks "Tasks" "List recent tasks, or run a task-graph query."
         '(:tail :query) #'run-cairn-tasks-command '(:model-visible nil))
   (list :resume "Resume" "Resume a task: select it and write a resume block into the transcript."
         '(:tail :id) #'run-cairn-resume-command '(:model-visible nil))
   (list :where "Where" "Show the resolved database path, project, and how it was resolved."
         nil #'run-cairn-where-command '(:model-visible nil))))

(defun register-cairn-commands (protocol contribution context)
  (declare (ignore protocol))
  (let ((commands (find-capability-provider (active-protocol context)
                                            :commands :contract :commands/v1))
        (source (contribution-extension contribution)))
    (when commands
      (loop for (name label description arguments runner metadata) in (cairn-command-specs)
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

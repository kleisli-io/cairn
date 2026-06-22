(in-package #:kli/cairn)

;;; Live per-turn task context, spliced into each model turn as ephemeral
;;; :user messages and never written to the durable log. Rebuilt every turn
;;; from the current pointer and the store, so it always reflects live state.

(defparameter *cairn-context-budget-chars* 4000
  "Upper bound on the injected context block; the injection budgets itself.")

(defun %swarm-conflict-line (db me slug &key (window-minutes 60))
  "A one-line note when other sessions are concurrently active on SLUG, else NIL."
  (let* ((cutoff (- (get-universal-time) (* window-minutes 60)))
         (n (sqlite:execute-single db
              "SELECT COUNT(*) FROM
                 (SELECT e.session_id
                    FROM events e
                    JOIN (SELECT session_id, MAX(seq) AS max_seq
                            FROM events
                           WHERE session_id IS NOT NULL AND ts >= ?
                           GROUP BY session_id) m
                      ON e.session_id = m.session_id AND e.seq = m.max_seq
                   WHERE e.task_id = ? AND (? IS NULL OR e.session_id <> ?))"
              cutoff slug me me)))
    (when (and n (plusp n))
      (format nil "  swarm: ~D other session~:P active on this task now.~%" n))))

(defun %truncate-chars (string n)
  (if (> (length string) n)
      (concatenate 'string (subseq string 0 n) (format nil "~%...(truncated)~%"))
      string))

(defun render-task-context (db slug session &key (budget *cairn-context-budget-chars*))
  "The live context block for SLUG: state, open handoffs, and a swarm note on
concurrent work. NIL when SLUG names no task. SESSION (the host session id, or
NIL) is excluded from the swarm count."
  (let ((state (%task-get-text db slug)))
    (when state
      (%truncate-chars
       (with-output-to-string (out)
         (format out "# Current task~%~A" state)
         (let ((h (%open-handoffs-text db slug))) (when h (write-string h out)))
         (let ((c (%swarm-conflict-line db session slug))) (when c (write-string c out))))
       budget))))

(defun cairn-extra-messages (context)
  "Ephemeral per-turn context as a list of :user messages, or NIL. Reads the
pointer and store live each call; holds no build-time state."
  (let ((slug (current-task-id context))
        (db (cairn-db (active-protocol context))))
    (when (and slug db)
      (let ((text (with-cairn-store-lock (context)
                    (render-task-context db slug (current-session-id context)))))
        (when (and text (plusp (length text)))
          (list (make-user-message text)))))))

(defun install-cairn-context (protocol contribution context)
  "Splice live task context into each turn by recoding the session's
extra-messages-fn. No-op (returns NIL) when no agent-session service is present."
  (declare (ignore protocol contribution))
  (let ((service (find-live-object (context-registry context) :agent-session-service)))
    (when service
      (let ((previous (getf (funcall (session-context-transform-policy service) :inspect)
                            :extra-messages-fn)))
        (recode-context-transform-policy
         service
         :extra-messages-fn
         (lambda ()
           (append (and previous (funcall previous))
                   (cairn-extra-messages context))))
        (list :service service :previous-fn previous)))))

(defun uninstall-cairn-context (protocol contribution context)
  (declare (ignore protocol context))
  (let ((state (contribution-state contribution)))
    (when state
      (recode-context-transform-policy
       (getf state :service)
       :extra-messages-fn (getf state :previous-fn)))))

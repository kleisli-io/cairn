(in-package #:kli/cairn)

;;; Fold the cairns recorded during a compacted span into the compaction
;;; summary, so the durable markers — not only the model's prose — survive a
;;; context cut. The session's compaction summarizer is recoded to a wrapper
;;; that calls the prior summarizer and prepends a span-scoped cairn block. The
;;; store is read only; the fold record rides the compaction entry's data slot.

(defparameter *cairn-compaction-budget-chars* 2000
  "Upper bound on the cairn block prepended to a compaction summary.")

(defparameter +cairn-compaction-watermark-key+ :kli/cairn/compaction-watermark
  "Protocol-storage key for the per-task highest already-folded timestamp.")

(defun %compaction-watermark (context slug)
  "The newest timestamp a prior fold already covered for SLUG, or NIL. Held
per-protocol in memory; never a durable write."
  (let ((table (protocol-storage (active-protocol context)
                                 +cairn-compaction-watermark-key+)))
    (and table (gethash slug table))))

(defun (setf %compaction-watermark) (ts context slug)
  (let* ((protocol (active-protocol context))
         (table (or (protocol-storage protocol +cairn-compaction-watermark-key+)
                    (setf (protocol-storage protocol +cairn-compaction-watermark-key+)
                          (make-hash-table :test #'equal)))))
    (setf (gethash slug table) ts)))

(defun %span-upper-bound (messages)
  "The newest timestamp across MESSAGES, or NIL when none carry one."
  (let ((hi (loop for m in messages
                  for ts = (message-timestamp m)
                  when (integerp ts) maximize ts)))
    (and (integerp hi) (plusp hi) hi)))

(defun %committed-compaction-watermark (agent-context slug)
  "Newest committed cairn fold boundary for SLUG in AGENT-CONTEXT's branch."
  (ignore-errors
    (let ((store (agent-context-store agent-context))
          (session (agent-context-session agent-context))
          (leaf-id (agent-context-leaf-id agent-context)))
      (when (and store session leaf-id)
        (loop for entry in (session-branch store session leaf-id)
              when (typep entry 'compaction-entry)
                maximize
                (let ((folded (getf (entry-data entry) :cairn-folded)))
                  (if (and (equal slug (getf folded :task-id))
                           (integerp (getf folded :ts-hi)))
                      (getf folded :ts-hi)
                      0)))))))

(defun render-compaction-cairns (db slug ts-lo ts-hi
                                 &key (budget *cairn-compaction-budget-chars*))
  "A char-budgeted block of SLUG's observations and handoffs whose timestamp
falls in (TS-LO, TS-HI], plus the folded obs and handoff ids. Returns
(values text obs-ids handoff-ids), or (values nil nil nil) when the span holds
no cairns. Read-only."
  (let ((obs (sqlite:execute-to-list db
               "SELECT o.obs_id, o.text FROM observations o
                  JOIN tasks t ON o.task_id = t.id
                 WHERE t.slug = ? AND o.ts > ? AND o.ts <= ?
                 ORDER BY o.ts, o.obs_id" slug ts-lo ts-hi))
        (handoffs (sqlite:execute-to-list db
                    "SELECT h.id, h.summary, h.path FROM handoffs h
                       JOIN tasks t ON h.task_id = t.id
                      WHERE t.slug = ? AND h.ts > ? AND h.ts <= ?
                      ORDER BY h.ts, h.id" slug ts-lo ts-hi)))
    (if (and (null obs) (null handoffs))
        (values nil nil nil)
        (values
         (%truncate-chars
          (with-output-to-string (out)
            (format out "# Cairns folded at this compaction~%task: ~A~%" slug)
            (when obs
              (format out "observations:~%")
              (dolist (o obs) (format out "  - ~A~%" (second o))))
            (when handoffs
              (format out "handoffs:~%")
              (dolist (h handoffs)
                (destructuring-bind (id summary path) h
                  (declare (ignore id))
                  (format out "  - ~A~@[ (~A)~]~%"
                          summary (and (stringp path) (plusp (length path)) path))))))
          budget)
         (mapcar #'first obs)
         (mapcar #'first handoffs)))))

(defun cairn-compaction-block (context messages &key agent-context)
  "The cairn block and fold details for the dropped span MESSAGES under CONTEXT's
current task, or (values nil nil) when there is nothing to fold. Read-only
against the store."
  (let ((db (cairn-db (active-protocol context)))
        (slug (current-task-id context)))
    (when (and db slug)
      (with-cairn-store-lock (context)
        (let ((ts-hi (%span-upper-bound messages)))
          (when ts-hi
            (let ((ts-lo (or (%committed-compaction-watermark agent-context slug)
                             (%compaction-watermark context slug)
                             0)))
              (multiple-value-bind (text obs-ids handoff-ids)
                  (render-compaction-cairns db slug ts-lo ts-hi)
                ;; Without a live session branch, fall back to a process-local
                ;; boundary.
                (unless agent-context
                  (setf (%compaction-watermark context slug) ts-hi))
                (when text
                  (values text
                          (list :cairn-folded
                                (list :task-id slug :ts-lo ts-lo :ts-hi ts-hi
                                      :session-id (current-session-id context)
                                      :observations obs-ids
                                      :handoffs handoff-ids))))))))))))

(defun install-cairn-compaction (protocol contribution context)
  "Recode the session's compaction summarizer to prepend a span-scoped cairn
block. No-op (returns NIL) when no agent-session service is present."
  (declare (ignore protocol contribution))
  (let ((service (find-live-object (context-registry context) :agent-session-service)))
    (when service
      (let ((previous (getf (funcall (session-compaction-policy service) :inspect)
                            :summarizer)))
        (recode-compaction-policy
         service
         :summarizer
         (lambda (&rest args)
           (multiple-value-bind (summary prior-details) (apply previous args)
             (multiple-value-bind (block details)
                 (ignore-errors
                   (cairn-compaction-block context (getf args :messages)
                                           :agent-context
                                           (getf args :agent-context)))
               (cond
                 ((null block) (values summary prior-details))
                 ((and (stringp summary) (plusp (length summary)))
                  (values (format nil "~A~2%~A" block summary)
                          (append details prior-details)))
                 (t (values block (append details prior-details))))))))
        (list :service service :previous-fn previous)))))

(defun uninstall-cairn-compaction (protocol contribution context)
  (declare (ignore protocol context))
  (let ((state (contribution-state contribution)))
    (when state
      (recode-compaction-policy
       (getf state :service)
       :summarizer (getf state :previous-fn)))))

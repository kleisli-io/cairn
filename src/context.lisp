(in-package #:kli/cairn)

;;; Live task context, spliced into model turns as ephemeral harness-context
;;; messages and never written to the durable log. Emitted when the task pointer
;;; changes or a resume is pending, so the context appears once at session start,
;;; on pointer change, or on resume — not repeated every turn. The trust split is
;;; the containment boundary: the structural task frame is operator authority,
;;; free-form observations and handoffs are reference data the transport fences
;;; and datamarks. cairn names no role, tag, or provider.

(defparameter *cairn-context-budget-chars* 4000
  "Per-message upper bound on injected harness context; the injection budgets
itself. Ephemeral content sits after the cache breakpoint and is re-sent every
turn, so an unbounded body is a per-turn token regression.")

(defun %truncate-chars (string n)
  (if (> (length string) n)
      (concatenate 'string (subseq string 0 n) (format nil "~%...(truncated)~%"))
      string))

(defun %render-task-reference (db slug)
  "Free-form, poisonable half for SLUG: description + metadata (model-authored),
then recent observations and open handoffs. NIL when there is none."
  (let* ((free (%task-free-text db slug))
         (id (%task-id db slug))
         (obs (and id (mapcar #'first
                              (sqlite:execute-to-list db
                                "SELECT text FROM observations WHERE task_id = ?
                                  ORDER BY ts DESC, obs_id DESC LIMIT 5" id))))
         (pointer (and obs (%earlier-observations-pointer
                            (%observation-count db id) (length obs))))
         (handoffs (%open-handoffs-text db slug))
         (s (with-output-to-string (out)
              (when free (write-string free out))
              (when obs
                (format out "recent observations:~%")
                (dolist (o obs) (format out "  - ~A~%" o))
                (when pointer (format out "  ~A~%" pointer)))
              (when handoffs (write-string handoffs out)))))
    (when (plusp (length s)) s)))

(defun render-harness-context-messages (db slug &key ephemeral)
  "Trust-split render of SLUG: recent observations, handoffs, and model-authored
free text become a :reference harness message; the structural task frame an
:operator one. REFERENCE first, OPERATOR last: an operator that lowers to a
midstream role:system must be the last `messages` entry, and the ephemeral block
is appended last each turn, so emitting the operator last keeps system valid.
EPHEMERAL marks per-turn injection (T) versus durable resume (NIL). Each body is
capped at *cairn-context-budget-chars*. NIL when SLUG names no task."
  (let ((ref (%render-task-reference db slug))
        (op (%task-operator-frame db slug)))
    (append
     (when ref
       (list (make-harness-context-message
              (%truncate-chars ref *cairn-context-budget-chars*)
              :trust :reference :ephemeral ephemeral)))
     (when (and op (plusp (length op)))
       (list (make-harness-context-message
              (%truncate-chars op *cairn-context-budget-chars*)
              :trust :operator :ephemeral ephemeral))))))

(defun cairn-extra-messages (context)
  "Ephemeral per-turn harness context as a list of harness-context messages, or
NIL. Reads the pointer and store live each call; holds no build-time state.
Emits only when the task pointer has changed since the last emission or a
resume is pending, so the context appears once at session start, on pointer
change, or on resume — not repeated every turn. After emitting, records the
slug and clears the resume-pending flag."
  (let ((slug (current-task-id context))
        (db (cairn-db (active-protocol context))))
    (when (and slug db)
      (with-cairn-store-lock (context)
        (if (and (equal slug (last-emitted-context-slug context))
                 (not (resume-context-pending context)))
            nil
            (progn
              (setf (last-emitted-context-slug context) slug
                    (resume-context-pending context) nil)
              (render-harness-context-messages db slug :ephemeral t)))))))

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

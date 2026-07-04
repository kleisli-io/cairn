(in-package #:kli/cairn)

;;; Per-protocol pointers. No image-global holds protocol state: both the open
;;; database handle and the current-task slug live keyed in the active
;;; protocol's own storage table, so two protocols never share either.

(defparameter +cairn-db-key+ :kli/cairn/db
  "Protocol-storage key for the per-protocol database handle.")

(defparameter +current-task-key+ :kli/cairn/current-task
  "Protocol-storage key for the per-protocol current-task slug.")

(defparameter +cairn-project-key+ :kli/cairn/project
  "Protocol-storage key for the per-protocol resolved project id.")

(defparameter +cairn-lock-key+ :kli/cairn/lock
  "Protocol-storage key for the mutex guarding the per-protocol connection.")

(defun cairn-db (protocol)
  "The open database handle for PROTOCOL, or NIL."
  (protocol-storage protocol +cairn-db-key+))

(defun ensure-cairn-db (context)
  "The database handle on CONTEXT's active protocol, opening it lazily when a
dump-time boot snapshot installed cairn without acquiring a SQLite handle."
  (let ((protocol (active-protocol context)))
    (or (cairn-db protocol)
        (when (extension-loaded-p protocol :cairn)
          (cairn-open-db protocol nil context)
          (cairn-db protocol)))))

(defun context-db (context)
  "The database handle on CONTEXT's active protocol; errors when the store is
not installed."
  (or (ensure-cairn-db context)
      (error 'cairn-store-error)))

(defun cairn-lock (context)
  "The mutex serializing access to CONTEXT's connection, or NIL."
  (protocol-storage (active-protocol context) +cairn-lock-key+))

(defun reconcile-live (context)
  "Refresh the open store from its logs so a call sees any peer's writes since the
last sweep. Epoch-gated and O(1) when idle; a no-op before the store is opened
\(the open path reconciles for itself). Reads `cairn-db`, never `ensure-cairn-db`,
so it never forces an open."
  (let ((db (cairn-db (active-protocol context))))
    (when db (reconcile-if-stale db))))

(defmacro with-cairn-store-lock ((context) &body body)
  "Hold the per-protocol connection mutex across BODY, refreshing the store from
its logs first so the call sees a peer's writes. A cl-sqlite handle is not safe
to share across threads, so every tool's reads and writes serialize on it."
  (let ((lock (gensym "LOCK"))
        (ctx (gensym "CTX")))
    `(let* ((,ctx ,context)
            (,lock (cairn-lock ,ctx)))
       (if ,lock
           (sb-thread:with-mutex (,lock)
             (reconcile-live ,ctx)
             ,@body)
           (progn
             (reconcile-live ,ctx)
             ,@body)))))

(defun current-task-id (context)
  "The per-protocol current-task slug, or NIL."
  (protocol-storage (active-protocol context) +current-task-key+))

(defun (setf current-task-id) (slug context)
  (setf (protocol-storage (active-protocol context) +current-task-key+) slug))

(defun current-project-id (context)
  "The resolved project id for the active protocol, or a fresh resolution before
the lazily opened store records one."
  (or (protocol-storage (active-protocol context) +cairn-project-key+)
      (cp-project-id (resolve-project context))))

(defun (setf current-project-id) (project-id context)
  (setf (protocol-storage (active-protocol context) +cairn-project-key+) project-id))

(defparameter +cairn-context-emitted-key+ :kli/cairn/context-emitted
  "Protocol-storage key for the slug last emitted as harness context.")

(defparameter +cairn-resume-pending-key+ :kli/cairn/resume-pending
  "Protocol-storage key for the resume-pending flag. Set by the resume
command, cleared after the next per-turn emission.")

(defun last-emitted-context-slug (context)
  "The slug last emitted as harness context, or NIL when none has been
emitted under this protocol."
  (protocol-storage (active-protocol context) +cairn-context-emitted-key+))

(defun (setf last-emitted-context-slug) (slug context)
  (setf (protocol-storage (active-protocol context) +cairn-context-emitted-key+) slug))

(defun resume-context-pending (context)
  "Whether a resume is pending, forcing one harness-context emission."
  (protocol-storage (active-protocol context) +cairn-resume-pending-key+))

(defun (setf resume-context-pending) (flag context)
  (setf (protocol-storage (active-protocol context) +cairn-resume-pending-key+) flag))
(defun %bare-slug (raw)
  "RAW stripped of any depot prefix, or NIL when RAW is empty."
  (when (and (stringp raw) (plusp (length raw)))
    (nth-value 1 (split-depot raw))))

(defun resolve-target-task (parameters context)
  "The :task_id argument when given, else the per-protocol current task.
Errors when neither names a task."
  (or (%bare-slug (tool-parameter parameters :task_id))
      (current-task-id context)
      (error "No current task; create or select one first.")))

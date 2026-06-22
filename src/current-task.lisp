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

(defun context-db (context)
  "The database handle on CONTEXT's active protocol; errors when the store is
not installed."
  (or (cairn-db (active-protocol context))
      (error 'cairn-store-error)))

(defun cairn-lock (context)
  "The mutex serializing access to CONTEXT's connection, or NIL."
  (protocol-storage (active-protocol context) +cairn-lock-key+))

(defmacro with-cairn-store-lock ((context) &body body)
  "Hold the per-protocol connection mutex across BODY. A cl-sqlite handle is not
safe to share across threads, so every tool's reads and writes serialize on it."
  (let ((lock (gensym "LOCK")))
    `(let ((,lock (cairn-lock ,context)))
       (if ,lock
           (sb-thread:with-mutex (,lock) ,@body)
           (progn ,@body)))))

(defun current-task-id (context)
  "The per-protocol current-task slug, or NIL."
  (protocol-storage (active-protocol context) +current-task-key+))

(defun (setf current-task-id) (slug context)
  (setf (protocol-storage (active-protocol context) +current-task-key+) slug))

(defun current-project-id (context)
  "The resolved project id for the active protocol, or NIL before install."
  (protocol-storage (active-protocol context) +cairn-project-key+))

(defun (setf current-project-id) (project-id context)
  (setf (protocol-storage (active-protocol context) +cairn-project-key+) project-id))

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

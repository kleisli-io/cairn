(in-package #:kli/cairn)

;;; Session identity is bound, never invented: the id is read from the host's
;;; current session. Absent a host session (headless), writes still record with
;;; a NULL session.

(defun %sole-mode-binding (bindings)
  "The unique mode binding when exactly one mode is bound, else NIL."
  (when (= 1 (hash-table-count bindings))
    (let (only)
      (maphash (lambda (k v) (declare (ignore k)) (setf only v)) bindings)
      only)))

(defun current-session-id (context &optional mode-id)
  "The host's current session id as a string, or NIL when no agent session is
bound. MODE-ID selects among several bound modes; absent, the sole bound mode is
used and ambiguity yields NIL."
  (let ((service (find-live-object (context-registry context)
                                   :agent-session-service)))
    (when service
      (let* ((bindings (session-mode-bindings service))
             (binding  (if mode-id
                           (gethash mode-id bindings)
                           (%sole-mode-binding bindings)))
             (sb       (and binding (mode-binding-session-binding binding))))
        (when sb
          (let ((id (session-binding-session-id sb)))
            (and id (princ-to-string id))))))))

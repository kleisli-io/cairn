(in-package #:kli/cairn/tests)
(in-suite all)

;;; Two protocols keep private caches over one shared log directory — the served
;;; layout, where each session's cache is its own file but the task logs are one
;;; bound tree. A write through one protocol must surface in the other on its
;;; next tool call, folded from the shared log under the connection mutex, with
;;; no reopen.

(defun install-cairn-stack (context)
  "Install the object, events, config, and cairn extensions on CONTEXT, opening
the store at the currently bound *cairn-db-path*."
  (install-extension context obj:*standard-object-extension-manifest*)
  (install-extension context event:*events-extension-manifest*)
  (install-extension context config:*config-extension-manifest*)
  (install-extension context cairn:*cairn-extension-manifest*))

(test a-peer-protocols-write-surfaces-on-the-next-tool-call
  "A creates a task and observes on it; B, opened over a distinct cache in the
same directory before that write, sees neither until its next tool call, whose
reconcile folds the shared log into B's cache."
  (let* ((root (temp-root))
         (db-dir (make-test-dir root "db")))
    (let ((config:*global-config-dir* (make-test-dir root "global"))
          (config:*project-start-directory* (make-test-dir root "proj")))
      (let* ((ctx-a (kli:make-kernel-host))
             (proto-a (switch-to-extension-protocol ctx-a))
             (ctx-b (kli:make-kernel-host))
             (proto-b (switch-to-extension-protocol ctx-b)))
        (let ((cairn:*cairn-db-path* (merge-pathnames "cairn-a.db" db-dir)))
          (install-cairn-stack ctx-a))
        (let ((cairn:*cairn-db-path* (merge-pathnames "cairn-b.db" db-dir)))
          (install-cairn-stack ctx-b))
        (is (not (eq (task-db proto-a) (task-db proto-b)))
            "the two protocols hold distinct cache handles")
        (with-cairn-tool-authority
          (ext:invoke-tool proto-a :task_create
                           (list :name "shared log cross visibility check") ctx-a)
          (let ((slug (cairn:current-task-id ctx-a)))
            (ext:invoke-tool proto-a :observe
                             (list :text "canary from protocol a" :task_id slug) ctx-a)
            (is (= 0 (sqlite:execute-single (task-db proto-b)
                       "SELECT count(*) FROM tasks"))
                "B has not reconciled yet: its cache is still empty")
            (ext:invoke-tool proto-b :timeline (list :task_id slug :limit 10) ctx-b)
            (is (= 1 (obs-count proto-b slug))
                "B's tool call folded A's observation into B's private cache")
            (is (cairn:verify (task-db proto-b))
                "B's cache still folds its own log after the reconcile")))))))

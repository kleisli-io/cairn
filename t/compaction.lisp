(in-package #:kli/cairn/tests)
(in-suite all)

;;; Folding span cairns into the compaction summary. The pure renderer and the
;;; window arithmetic are tested over the store; the recode seam is driven
;;; through a standalone agent-session service whose summarizer is a stub, so the
;;; wrapper's prepend, reversibility, and read-only contract are exercised
;;; without the full agent stack.

(defparameter +ct0+ 3900000000
  "A base CL universal-time; offsets from it stay above the epoch-shift cutoff,
so canonical-ts passes them through unchanged.")

(defun seed-observation (db slug text ts)
  (cairn:record-event db slug "observation" (list :text text) :raw-ts ts))

(defmacro with-cairn-compaction-protocol ((context-var protocol-var cairn-var service-var)
                                          &body body)
  "Like WITH-CAIRN-PROTOCOL but with a standalone agent-session service whose
compaction summarizer returns a fixed marker, registered before cairn so the
compaction effect recodes it."
  (let ((root (gensym "ROOT")))
    `(let* ((,root (temp-root))
            (,context-var (kli:make-kernel-host))
            (,protocol-var (switch-to-extension-protocol ,context-var))
            (,service-var
              (session:make-agent-session-service
               :compaction-policy
               (session:make-compaction-policy
                :summarizer (lambda (&rest ignored)
                              (declare (ignore ignored))
                              "LLM-SUMMARY")))))
       (let ((config:*global-config-dir* (make-test-dir ,root "global"))
             (config:*project-start-directory* (make-test-dir ,root "proj"))
             (cairn:*cairn-db-path*
               (merge-pathnames "cairn.db" (make-test-dir ,root "db"))))
         (install-extension ,context-var obj:*standard-object-extension-manifest*)
         (install-extension ,context-var event:*events-extension-manifest*)
         (install-extension ,context-var config:*config-extension-manifest*)
         (kli::register-live-object (kli:context-registry ,context-var) ,service-var)
         (let ((,cairn-var
                 (install-extension ,context-var cairn:*cairn-extension-manifest*)))
           (declare (ignorable ,cairn-var))
           (with-cairn-tool-authority ,@body))))))

(defun stub-messages (&rest timestamps)
  (mapcar (lambda (ts) (log:make-user-message "dropped" :timestamp ts)) timestamps))

(defun summarize (service &rest args)
  (apply (session:session-compaction-policy service) :summarize args))

;;; --- The pure renderer over the store ---

(test render-folds-observations-inside-the-window
  (with-cairn-protocol (context protocol)
    (declare (ignore context))
    (let ((db (task-db protocol)))
      (seed-observation db "the folded task" "an in-window cairn" (+ +ct0+ 50))
      (multiple-value-bind (text obs handoffs)
          (cairn::render-compaction-cairns db "the folded task" 0 (+ +ct0+ 100))
        (declare (ignore handoffs))
        (is (search "Cairns folded" text) "the block is headed")
        (is (search "an in-window cairn" text) "the in-window observation is folded")
        (is (= 1 (length obs)) "its id is returned")
        (is (integerp (first obs)) "the folded id is an integer")))))

(test render-excludes-observations-outside-the-window
  (with-cairn-protocol (context protocol)
    (declare (ignore context))
    (let ((db (task-db protocol)))
      (seed-observation db "the windowed task" "below the floor" (+ +ct0+ 10))
      (seed-observation db "the windowed task" "above the ceiling" (+ +ct0+ 900))
      (seed-observation db "the windowed task" "inside the window" (+ +ct0+ 500))
      (multiple-value-bind (text obs handoffs)
          (cairn::render-compaction-cairns db "the windowed task"
                                           (+ +ct0+ 100) (+ +ct0+ 600))
        (declare (ignore handoffs))
        (is (= 1 (length obs)) "only the in-window observation is folded")
        (is (search "inside the window" text))
        (is (null (search "below the floor" text)) "the lower bound is exclusive of older cairns")
        (is (null (search "above the ceiling" text)) "the upper bound excludes newer cairns")))))

(test render-is-task-scoped
  "Two tasks sharing one store: only the named task's cairns are folded."
  (with-cairn-protocol (context protocol)
    (declare (ignore context))
    (let ((db (task-db protocol)))
      (seed-observation db "task-a" "cairn on a" (+ +ct0+ 50))
      (seed-observation db "task-b" "cairn on b" (+ +ct0+ 50))
      (multiple-value-bind (text obs handoffs)
          (cairn::render-compaction-cairns db "task-a" 0 (+ +ct0+ 100))
        (declare (ignore handoffs))
        (is (= 1 (length obs)))
        (is (search "cairn on a" text))
        (is (null (search "cairn on b" text)) "a sibling task's cairns are not folded")))))

(test render-returns-nil-for-an-empty-span
  (with-cairn-protocol (context protocol)
    (declare (ignore context))
    (let ((db (task-db protocol)))
      (seed-observation db "the empty span task" "out of range" (+ +ct0+ 5))
      (is (null (cairn::render-compaction-cairns db "the empty span task"
                                                 (+ +ct0+ 100) (+ +ct0+ 200)))
          "a window with no cairns folds nothing"))))

;;; --- The recode seam ---

(test install-compaction-is-a-no-op-without-an-agent-session
  (with-cairn-protocol (context protocol)
    (is (null (cairn::install-cairn-compaction protocol nil context)))))

(test summarizer-prepends-the-cairn-block-and-keeps-the-llm-summary
  (with-cairn-compaction-protocol (context protocol cairn service)
    (declare (ignore cairn))
    (ext:invoke-tool protocol :task_create (list :name "the compacted task") context)
    (let ((slug (cairn:current-task-id context)))
      (seed-observation (task-db protocol) slug "a note from the dropped span" (+ +ct0+ 30))
      (multiple-value-bind (summary details)
          (summarize service :messages (stub-messages (+ +ct0+ 50)) :context context)
        (is (search "a note from the dropped span" summary) "the cairn block is present")
        (is (search "LLM-SUMMARY" summary) "the prior summary is kept")
        (let ((folded (getf details :cairn-folded)))
          (is (string= slug (getf folded :task-id)) "the fold record names the task")
          (is (integerp (getf folded :ts-hi)) "the window ceiling is recorded")
          (is (= 1 (length (getf folded :observations))) "the folded obs id is recorded")
          (is (integerp (first (getf folded :observations)))
              "the folded id is a serializable integer"))))))

(test summarizer-with-no-span-cairns-keeps-only-the-llm-summary
  (with-cairn-compaction-protocol (context protocol cairn service)
    (declare (ignore cairn))
    (ext:invoke-tool protocol :task_create (list :name "the cairn-free task") context)
    (multiple-value-bind (summary details)
        (summarize service :messages (stub-messages (+ +ct0+ 50)) :context context)
      (is (string= "LLM-SUMMARY" summary) "a cairn-free span returns the bare summary")
      (is (null (getf details :cairn-folded)) "no fold record is attached"))))

(test deactivation-restores-the-prior-summarizer
  (with-cairn-compaction-protocol (context protocol cairn service)
    (ext:invoke-tool protocol :task_create (list :name "the reversible task") context)
    (let ((slug (cairn:current-task-id context)))
      (seed-observation (task-db protocol) slug "a fold candidate" (+ +ct0+ 30))
      (is (search "a fold candidate"
                  (summarize service :messages (stub-messages (+ +ct0+ 50)) :context context))
          "the cairn block is folded while installed")
      (with-extension-load-authority
        (ext:deactivate-extension protocol cairn context))
      (let ((summary (summarize service :messages (stub-messages (+ +ct0+ 999)) :context context)))
        (is (string= "LLM-SUMMARY" summary) "the bare summarizer is restored")
        (is (null (search "fold candidate" summary)) "no cairn block after teardown")))))

(test watermark-advances-and-never-refolds-a-prior-span
  "Successive compactions move the lower bound to the prior boundary: the second
cut folds the kept-window cairn (proving the bound is the watermark, not the
dropped span's earliest message) and never re-folds the first cut's cairn."
  (with-cairn-compaction-protocol (context protocol cairn service)
    (declare (ignore cairn))
    (ext:invoke-tool protocol :task_create (list :name "the two-cut task") context)
    (let ((slug (cairn:current-task-id context))
          (db (task-db protocol)))
      (seed-observation db slug "first-cut cairn" (+ +ct0+ 100))
      (seed-observation db slug "kept-window cairn" (+ +ct0+ 210))
      (seed-observation db slug "second-cut cairn" (+ +ct0+ 280))
      (let ((cut1 (summarize service :messages (stub-messages (+ +ct0+ 200)) :context context)))
        (is (search "first-cut cairn" cut1) "the first cut folds its span")
        (is (null (search "second-cut cairn" cut1)) "later cairns are not folded early"))
      ;; Second cut drops messages whose earliest ts is 260 — past the kept-window
      ;; cairn at 210. The watermark (200) is the lower bound, so 210 is still folded.
      (let ((cut2 (summarize service
                             :messages (stub-messages (+ +ct0+ 260) (+ +ct0+ 300))
                             :context context)))
        (is (search "kept-window cairn" cut2)
            "the bound is the prior boundary, not the dropped span's earliest message")
        (is (search "second-cut cairn" cut2) "the second span's cairn is folded")
        (is (null (search "first-cut cairn" cut2)) "the first cut's cairn is not re-folded")))))

(test agent-context-mode-does-not-advance-watermark-before-commit
  "KLI can retry a compaction before committing the first summarizer result; the
retry must still fold cairns from the earlier pre-commit span."
  (with-cairn-compaction-protocol (context protocol cairn service)
    (declare (ignore cairn service))
    (ext:invoke-tool protocol :task_create (list :name "the retry task") context)
    (let ((slug (cairn:current-task-id context))
          (db (task-db protocol)))
      (seed-observation db slug "first attempt cairn" (+ +ct0+ 50))
      (seed-observation db slug "retry attempt cairn" (+ +ct0+ 100))
      (cairn::cairn-compaction-block
       context (stub-messages (+ +ct0+ 60))
       :agent-context :pre-commit-retry)
      (multiple-value-bind (retry-summary details)
          (cairn::cairn-compaction-block
           context (stub-messages (+ +ct0+ 120))
           :agent-context :pre-commit-retry)
        (is (search "first attempt cairn" retry-summary)
            "the first attempt's cairn is still folded on retry")
        (is (search "retry attempt cairn" retry-summary)
            "the retry span's cairn is folded")
        (is (= 2 (length (getf (getf details :cairn-folded) :observations)))
            "both folded ids are recorded in the committed candidate")))))

(test summarizing-does-not-write-the-store
  "A summarize is read-only: the event and projection rows are unchanged."
  (with-cairn-compaction-protocol (context protocol cairn service)
    (declare (ignore cairn))
    (ext:invoke-tool protocol :task_create (list :name "the read-only task") context)
    (let* ((slug (cairn:current-task-id context))
           (db (task-db protocol)))
      (seed-observation db slug "the immutable cairn" (+ +ct0+ 30))
      (flet ((counts ()
               (list (sqlite:execute-single db "SELECT count(*) FROM events")
                     (sqlite:execute-single db "SELECT count(*) FROM observations")
                     (sqlite:execute-single db "SELECT count(*) FROM handoffs"))))
        (let ((before (counts)))
          (summarize service :messages (stub-messages (+ +ct0+ 50)) :context context)
          (is (equal before (counts)) "no rows were inserted, updated, or deleted"))))))

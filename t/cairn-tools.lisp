(in-package #:kli/cairn/tests)
(in-suite all)

(defparameter +cairn-tool-names+
  '("observe" "task_create" "task_fork" "task_link" "task_sever"
    "task_set_metadata" "task_update_status" "handoff"
    "task_search" "task_get" "timeline" "task_query" "task_query_write"
    "task_bootstrap"))

(defun tool-text (result)
  "The concatenated text of a tool result's content."
  (with-output-to-string (out)
    (dolist (item (ext:tool-result-content result))
      (write-string (getf item :text "") out))))

(defun created-slug (result)
  "The slug from a 'Created <slug>.' tool result."
  (let ((text (tool-text result)))
    (subseq text (length "Created ") (position #\. text :from-end t))))

(defun task-db (protocol)
  (ext:protocol-storage protocol cairn:+cairn-db-key+))

(defun obs-count (protocol slug)
  (sqlite:execute-single (task-db protocol)
    "SELECT count(*) FROM observations o JOIN tasks t ON o.task_id = t.id
      WHERE t.slug = ?" slug))

;;; A downstream mirror that captures the bus pointer, proving emission is wired
;;; without making it the record.
(defvar *captured-cairn-events* nil)

(ext:defextension capture-cairn-events
  (:requires
   (capability events :contract events/v1))
  (:provides
   (event-handler capture
     :event-type :cairn/observation
     :handler (lambda (event context)
                (declare (ignore context))
                (push event *captured-cairn-events*)))))

(test tools-are-enumerable-on-the-protocol
  "Activating the extension surfaces all fourteen tools to the model."
  (with-cairn-protocol (context protocol)
    (declare (ignore context))
    (let ((names (mapcar #'ext:tool-name (ext:list-tools protocol))))
      (dolist (name +cairn-tool-names+)
        (is (member name names :test #'string=)
            "~A is registered" name)))))

(test observe-records-on-the-current-task-and-is-searchable
  "task_create sets the per-protocol pointer; observe with no task_id records on
it and the note is immediately full-text searchable."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "implement the cairn tool runners") context)
    (let ((slug (cairn:current-task-id context)))
      (is (not (null slug)))
      (let ((result (ext:invoke-tool protocol :observe
                                     (list :text "the canary token is here") context)))
        (is (not (ext:tool-result-error-p result))))
      (is (= 1 (obs-count protocol slug)))
      (is (plusp (sqlite:execute-single (task-db protocol)
                   "SELECT count(*) FROM obs_fts WHERE obs_fts MATCH 'canary'"))
          "the observation is in the full-text index"))))

(test observe-requires-text
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create (list :name "a task for the blank check") context)
    (is (ext:tool-result-error-p
         (ext:invoke-tool protocol :observe (list :text "") context)))))

(test the-current-task-pointer-is-per-protocol
  "One protocol's current task and rows are invisible to another (per-protocol
storage)."
  (with-cairn-protocol (ctx-a proto-a)
    (with-cairn-protocol (ctx-b proto-b)
      (ext:invoke-tool proto-a :task_create
                       (list :name "alpha task lives in protocol a") ctx-a)
      (is (not (null (cairn:current-task-id ctx-a))))
      (is (null (cairn:current-task-id ctx-b))
          "the second protocol has no current task")
      (is (= 0 (sqlite:execute-single (task-db proto-b) "SELECT count(*) FROM tasks"))
          "the second protocol's store is untouched"))))

(test task-fork-creates-a-child-edge-and-moves-the-pointer
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create (list :name "the parent task here") context)
    (let ((parent (cairn:current-task-id context)))
      (ext:invoke-tool protocol :task_fork (list :name "the child subtask here") context)
      (let ((child (cairn:current-task-id context)))
        (is (not (string= parent child)) "the pointer moved to the child")
        (is (string= parent
                     (sqlite:execute-single (task-db protocol)
                       "SELECT p.slug FROM tasks c JOIN tasks p ON c.parent_task_id = p.id
                         WHERE c.slug = ?" child))
            "the child's parent is the forked-from task")))))

(test status-update-validates-is-idempotent-and-reopens
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create (list :name "the status lifecycle task") context)
    (let ((slug (cairn:current-task-id context)))
      (flet ((status () (sqlite:execute-single (task-db protocol)
                          "SELECT status FROM tasks WHERE slug = ?" slug)))
        (is (ext:tool-result-error-p
             (ext:invoke-tool protocol :task_update_status (list :status "wat") context))
            "an out-of-enum status is rejected")
        (ext:invoke-tool protocol :task_update_status (list :status "completed") context)
        (is (string= "completed" (status)))
        (ext:invoke-tool protocol :task_update_status (list :status "completed") context)
        (is (string= "completed" (status)) "re-completing is a no-op")
        (ext:invoke-tool protocol :task_update_status (list :reopen t) context)
        (is (string= "active" (status)) "reopen revives a completed task")))))

(test link-validates-the-edge-enum-and-rejects-self-loops
  (with-cairn-protocol (context protocol)
    (let ((src (created-slug
                (ext:invoke-tool protocol :task_create
                                 (list :name "the link source task") context)))
          (target (created-slug
                   (ext:invoke-tool protocol :task_create
                                    (list :name "the link target task") context))))
      (is (ext:tool-result-error-p
           (ext:invoke-tool protocol :task_link
                            (list :target_id target :edge_type "bogus" :task_id src) context))
          "an unknown edge type is rejected")
      (is (ext:tool-result-error-p
           (ext:invoke-tool protocol :task_link
                            (list :target_id src :edge_type "related" :task_id src) context))
          "a self-loop is rejected")
      (ext:invoke-tool protocol :task_link
                       (list :target_id target :edge_type "depends-on" :task_id src) context)
      (is (= 1 (sqlite:execute-single (task-db protocol)
                 "SELECT count(*) FROM edges e
                    JOIN tasks s ON e.src_id = s.id JOIN tasks d ON e.dst_id = d.id
                   WHERE s.slug = ? AND d.slug = ? AND e.type = 'depends-on'" src target))))))

(test the-capability-gate-denies-writes-but-allows-observe-and-read
  "A restricted subject lacking :cairn/write is denied a write tool yet may
still observe and search; the default subject passes everything."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create (list :name "seed the capability gate test") context)
    (let ((ext:*call-subject*
            (ext:make-subject :capabilities '(:cairn/observe :cairn/read))))
      (signals ext:capability-denied
        (ext:invoke-tool protocol :task_create
                         (list :name "this create must be denied") context))
      (signals ext:capability-denied
        (ext:invoke-tool protocol :task_query_write
                         (list :query "(define! \"x\" (active))") context))
      (is (not (ext:tool-result-error-p
                (ext:invoke-tool protocol :observe (list :text "still allowed") context)))
          "observe passes with :cairn/observe")
      (is (not (ext:tool-result-error-p
                (ext:invoke-tool protocol :task_search (list :query "x") context)))
          "search passes with :cairn/read")
      (is (not (ext:tool-result-error-p
                (ext:invoke-tool protocol :task_query (list :query "(active)") context)))
          "task_query passes with :cairn/read"))))

(test reads-report-state-and-timeline
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create (list :name "the readable state task") context)
    (let ((slug (cairn:current-task-id context)))
      (ext:invoke-tool protocol :observe (list :text "a recorded note") context)
      (let ((get (tool-text (ext:invoke-tool protocol :task_get '() context)))
            (tl (tool-text (ext:invoke-tool protocol :timeline '() context))))
        (is (search slug get) "task_get names the task")
        (is (search "active" get) "task_get reports the status")
        (is (search "observation" tl) "the timeline lists the observation event")
        (is (search "a recorded note" tl) "the timeline shows the observation text")))))

(test a-durable-write-emits-the-bus-pointer
  "After a durable append the store emits a thin :cairn/observation pointer
(task-id + seq), captured by a downstream handler."
  (with-cairn-protocol (context protocol)
    (let ((*captured-cairn-events* nil))
      (install-extension context *capture-cairn-events-extension-manifest*)
      (ext:invoke-tool protocol :task_create (list :name "the bus pointer task") context)
      (is (= 1 (length *captured-cairn-events*)) "one append, one pointer")
      (let ((payload (event:event-payload (first *captured-cairn-events*))))
        (is (stringp (getf payload :task-id)))
        (is (integerp (getf payload :seq)))
        (is (plusp (getf payload :seq)))))))

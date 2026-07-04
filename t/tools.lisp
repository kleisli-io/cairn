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

(test minting-does-not-double-a-caller-supplied-date-prefix
  "A name the caller already date-prefixed mints to a single date namespace, not
a doubled one — forking a YYYY-MM-DD-... task stays canonical and idempotent."
  (let* ((today (kli/cairn::%today-prefix))
         (core "tier2b-structural-ktype-validate-research")
         (canonical (kli/cairn::%mint-slug core)))
    (is (string= (format nil "~A-~A" today core) canonical)
        "a bare core mints to today-prefix + core")
    (is (string= canonical (kli/cairn::%mint-slug canonical))
        "re-minting an already-prefixed slug is a no-op (idempotent)")
    (is (string= canonical
                 (kli/cairn::%mint-slug
                  (format nil "~A-~A-~A" today today core)))
        "even a doubled date prefix collapses to a single namespace")))

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

(test timeline-selects-by-type-and-seq-window
  "timeline filters to the requested event types and to an exclusive
(after_seq, before_seq) window; omitting both leaves the stream unchanged."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "the timeline selection task") context)
    (ext:invoke-tool protocol :observe (list :text "note-one about alpha") context)
    (ext:invoke-tool protocol :observe (list :text "note-two about beta") context)
    (ext:invoke-tool protocol :task_set_metadata (list :key "tag" :value "x") context)
    (ext:invoke-tool protocol :observe (list :text "note-three about gamma") context)
    (let ((slug (cairn:current-task-id context)))
      (flet ((tl (&rest args)
               (tool-text (ext:invoke-tool protocol :timeline args context))))
        (let ((obs (tl :types "observation")))
          (is (search "note-one about alpha" obs))
          (is (search "note-three about gamma" obs))
          (is (not (search "task.set-metadata" obs))
              "types=observation excludes the metadata event"))
        (let ((both (tl :types "observation,task.set-metadata")))
          (is (search "note-two about beta" both) "the CSV admits observations")
          (is (search "task.set-metadata" both) "the CSV admits each named type"))
        (let ((all (tl)))
          (is (search "task.set-metadata" all))
          (is (search "note-one about alpha" all)
              "omitted types = every event type"))
        (destructuring-bind (s1 s2 s3)
            (mapcar #'first
                    (sqlite:execute-to-list (task-db protocol)
                      "SELECT seq FROM events WHERE task_id = ? AND type = 'observation'
                        ORDER BY seq" slug))
          (declare (ignore s2))
          (let ((mid (tl :after_seq s1 :before_seq s3)))
            (is (search "note-two about beta" mid) "the window keeps the interior event")
            (is (not (search "note-one about alpha" mid)) "after_seq is an exclusive floor")
            (is (not (search "note-three about gamma" mid)) "before_seq is an exclusive ceiling")))))))

(test timeline-unknown-type-errors-with-a-suggestion
  "A mistyped type is a hard error naming the nearest live type, never a
silent-empty result."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "the unknown timeline type task") context)
    (ext:invoke-tool protocol :observe (list :text "a recorded note") context)
    (let ((result (ext:invoke-tool protocol :timeline (list :types "observaton") context)))
      (is (ext:tool-result-error-p result) "an unknown type errors, not silent-empty")
      (is (search "did you mean observation?" (tool-text result))
          "the error names the nearest match"))))

(test timeline-non-full-rendering-is-unchanged
  "Without full, timeline emits the historical one-line digest form exactly —
whitespace collapsed, no timestamp — byte-for-byte."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create (list :name "the digest fixture task") context)
    (ext:invoke-tool protocol :observe
                     (list :text (format nil "collapsed~%across~%lines")) context)
    (let* ((slug (cairn:current-task-id context))
           (s-obs (sqlite:execute-single (task-db protocol)
                    "SELECT seq FROM events WHERE task_id = ? AND type = 'observation'" slug))
           (s-create (sqlite:execute-single (task-db protocol)
                       "SELECT seq FROM events WHERE task_id = ? AND type = 'task.create'" slug))
           (expected (format nil "~A — last 2 events~%  ~D  observation  collapsed across lines~%  ~D  task.create~%"
                             slug s-obs s-create))
           (actual (tool-text (ext:invoke-tool protocol :timeline '() context))))
      (is (string= expected actual)
          "non-full timeline is byte-for-byte the digest form"))))

(test timeline-full-renders-observations-verbatim
  "full keeps multi-line observation bodies intact — newlines preserved, no
ellipsis, no 140-char cut — under a header carrying seq, type, and a
minute-precision UTC timestamp."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create (list :name "the full render task") context)
    (let ((long (make-string 200 :initial-element #\x))
          (multi (format nil "para one~%~%para two with detail")))
      (ext:invoke-tool protocol :observe (list :text multi) context)
      (ext:invoke-tool protocol :observe (list :text long) context)
      (let* ((slug (cairn:current-task-id context))
             (out (tool-text (ext:invoke-tool protocol :timeline (list :full t) context))))
        (is (search (format nil "para one~%") out) "newlines are preserved")
        (is (search "para two with detail" out) "the whole body survives")
        (is (search long out) "a 200-char line is not cut at 140")
        (is (not (find #\… out)) "full output carries no digest ellipsis")
        (let ((obs-seq (sqlite:execute-single (task-db protocol)
                         "SELECT max(seq) FROM events WHERE task_id = ? AND type = 'observation'"
                         slug)))
          (is (search (format nil "~D  observation  (" obs-seq) out)
              "the header is <seq>  <type>  (timestamp"))
        (let* ((mark "  observation  (")
               (start (+ (search mark out) (length mark)))
               (end (search " UTC)" out :start2 start)))
          (is (= 16 (- end start))
              "the timestamp is minute-precision YYYY-MM-DD HH:MM, no seconds"))))))

(test timeline-ceiling-truncates-and-pages-back
  "Over the output budget, timeline stops before the overflowing event and prints
a continuation cursor; feeding that before_seq back returns the next older page
with no gap and no overlap. Below the budget nothing is truncated."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create (list :name "the output ceiling task") context)
    (dotimes (i 6)
      (ext:invoke-tool protocol :observe
                       (list :text (format nil "observation body number ~D with padding ~A"
                                           i (make-string 40 :initial-element #\z)))
                       context))
    (flet ((tl (&rest args) (tool-text (ext:invoke-tool protocol :timeline args context)))
           (nums (s) (loop for i below 6 when (search (format nil "number ~D " i) s) collect i)))
      (let ((untruncated (tl :full t :limit 50)))
        (is (not (search "truncated at" untruncated))
            "below the budget nothing is truncated")
        (let ((cairn::*cairn-timeline-output-budget-chars* 300))
          (let* ((out (tl :full t :limit 50))
                 (nums-out (nums out)))
            (is (search "truncated at" out) "the ceiling trips over budget")
            (is (search "before_seq=" out) "the continuation names a page-back cursor")
            (is (search "remaining" out) "the continuation reports the remaining count")
            (is (< (length out) (length untruncated))
                "the ceiling shortens the output")
            (is (member 5 nums-out) "the newest event is shown first")
            (let* ((mark "before_seq=")
                   (pos (search mark out))
                   (cursor (parse-integer out :start (+ pos (length mark)) :junk-allowed t))
                   (page2 (tl :full t :limit 50 :before_seq cursor))
                   (nums-p2 (nums page2)))
              (is (null (intersection nums-out nums-p2))
                  "no event repeats across the page break")
              (is (= (1- (apply #'min nums-out)) (apply #'max nums-p2))
                  "the next page resumes exactly one event older — no gap"))))))))

(test task-get-points-past-the-observation-cap
  "task_get shows the capped five observations plus a one-line pointer to the
full history when more exist, naming full=true and types=observation; a task at
or under the cap shows no pointer."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create (list :name "the capped observations task") context)
    (dotimes (i 8)
      (ext:invoke-tool protocol :observe (list :text (format nil "capped note ~D" i)) context))
    (let ((out (tool-text (ext:invoke-tool protocol :task_get '() context))))
      (is (search "3 earlier observation" out) "the pointer names N = count − shown")
      (is (search "full=true" out) "the pointer names the full flag")
      (is (search "types=observation" out) "the pointer names the observation type"))
    (let ((few (created-slug
                (ext:invoke-tool protocol :task_create
                                 (list :name "the under-cap task") context))))
      (setf (cairn:current-task-id context) few)
      (dotimes (i 3)
        (ext:invoke-tool protocol :observe (list :text (format nil "small note ~D" i)) context))
      (let ((out (tool-text (ext:invoke-tool protocol :task_get '() context))))
        (is (not (search "earlier observation" out))
            "at or under the cap there is no pointer")))))

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

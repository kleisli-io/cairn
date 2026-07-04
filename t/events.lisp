(in-package #:kli/cairn/tests)
(in-suite all)

(defmacro with-event-store ((db) &body body)
  "A fresh store opened on a private temp file, closed after BODY."
  `(let ((,db (cairn:open-cairn-store
               (namestring (merge-pathnames "cairn.db"
                                            (make-test-dir (temp-root) "ev"))))))
     (unwind-protect (progn ,@body)
       (cairn:close-cairn-store ,db))))

(defun task-children (db slug)
  (mapcar #'first
          (sqlite:execute-to-list db
            "SELECT c.slug FROM tasks c JOIN tasks p ON c.parent_task_id = p.id
              WHERE p.slug = ? ORDER BY c.slug" slug)))

(defun task-parent (db slug)
  (sqlite:execute-single db
    "SELECT p.slug FROM tasks c JOIN tasks p ON c.parent_task_id = p.id
      WHERE c.slug = ?" slug))

(defun task-edges (db slug)
  (sqlite:execute-to-list db
    "SELECT d.slug, e.type, IFNULL(e.tag, '') FROM edges e
       JOIN tasks s ON e.src_id = s.id JOIN tasks d ON e.dst_id = d.id
      WHERE s.slug = ? ORDER BY d.slug, e.type" slug))

(test store-open-creates-the-full-schema
  "Opening a store applies the entire DDL and stamps the schema version."
  (with-event-store (db)
    (let ((tables (mapcar #'first
                          (sqlite:execute-to-list db
                            "SELECT name FROM sqlite_master WHERE type = 'table'"))))
      (dolist (tbl '("schema_meta" "events" "tasks" "edges" "observations"
                     "obs_fts" "handoffs" "task_metadata" "artifacts" "projects"
                     "named_views"))
        (is (member tbl tables :test #'string=) "table ~A exists" tbl)))
    (is (string= "1" (sqlite:execute-single db
                       "SELECT value FROM schema_meta WHERE key = 'schema_version'")))))

(test record-event-round-trips-task-observation-and-status
  "A create, an observation, and a status update materialize into the
projection, and the observation is full-text searchable."
  (with-event-store (db)
    (cairn:record-event db "alpha" "task.create" '(:description "the alpha task")
                        :raw-ts 3990000001)
    (cairn:record-event db "alpha" "observation" '(:text "keeps task_fork whole")
                        :raw-ts 3990000002)
    (cairn:record-event db "alpha" "task.update-status" '(:status "completed")
                        :raw-ts 3990000003)
    (is (string= "the alpha task"
                 (sqlite:execute-single db "SELECT description FROM tasks WHERE slug = 'alpha'")))
    (is (string= "completed"
                 (sqlite:execute-single db "SELECT status FROM tasks WHERE slug = 'alpha'")))
    (is (equal '(("keeps task_fork whole"))
               (sqlite:execute-to-list db
                 "SELECT text FROM obs_fts WHERE obs_fts MATCH 'task_fork'")))))

(test status-is-lww-and-reemit-is-a-noop
  "completed -> active -> completed yields three events and a final completed;
re-emitting the same status event is ignored."
  (with-event-store (db)
    (cairn:record-event db "t" "task.create" '() :raw-ts 3990000000)
    (cairn:record-event db "t" "task.update-status" '(:status "completed") :raw-ts 3990000001)
    (cairn:record-event db "t" "task.update-status" '(:status "active") :raw-ts 3990000002)
    (cairn:record-event db "t" "task.update-status" '(:status "completed") :raw-ts 3990000003)
    (is (string= "completed"
                 (sqlite:execute-single db "SELECT status FROM tasks WHERE slug = 't'")))
    (is (= 3 (sqlite:execute-single db
               "SELECT count(*) FROM events WHERE type = 'task.update-status'")))
    (is (null (cairn:record-event db "t" "task.update-status" '(:status "completed")
                                  :raw-ts 3990000003))
        "a duplicate status event returns NIL")
    (is (= 3 (sqlite:execute-single db
               "SELECT count(*) FROM events WHERE type = 'task.update-status'")))))

(test reducer-edge-direction-parity
  "A downward fork and an upward phase-of link both set the child's parent FK;
the upward-linking child gains no children, so its parent is never enumerated
as a pseudo-child."
  (with-event-store (db)
    (cairn:record-event db "P" "task.create" '() :raw-ts 3990001000)
    (cairn:record-event db "P" "task.fork" '(:child-id "A" :edge-type "phase-of")
                        :raw-ts 3990001001)
    (cairn:record-event db "P" "task.fork" '(:child-id "B" :edge-type "forked-from")
                        :raw-ts 3990001002)
    (cairn:record-event db "C" "task.create" '() :raw-ts 3990001003)
    (cairn:record-event db "C" "task.link" '(:target-id "P" :edge-type "phase-of")
                        :raw-ts 3990001004)
    (is (string= "P" (task-parent db "A")))
    (is (string= "P" (task-parent db "B")))
    (is (string= "P" (task-parent db "C")))
    (is (null (task-children db "C")))
    (is (equal '("A" "B" "C") (task-children db "P")))))

(test reducer-lateral-edges-reclassify-and-sever
  "Lateral links land in edges with aliases normalized to a tag; reclassify
swaps the type; sever clears a structural parent FK."
  (with-event-store (db)
    (cairn:record-event db "X" "task.create" '() :raw-ts 3990002000)
    (cairn:record-event db "X" "task.link" '(:target-id "Y" :edge-type "depends-on")
                        :raw-ts 3990002001)
    (cairn:record-event db "X" "task.link" '(:target-id "Z" :edge-type "blocks")
                        :raw-ts 3990002002)
    (is (equal '(("Y" "depends-on" "") ("Z" "depends-on" "blocks"))
               (task-edges db "X")))
    (cairn:record-event db "X" "task.reclassify"
                        '(:target-id "Y" :old-type "depends-on" :new-type "related")
                        :raw-ts 3990002003)
    (is (equal '(("Y" "related" "") ("Z" "depends-on" "blocks"))
               (task-edges db "X")))
    (cairn:record-event db "Pp" "task.create" '() :raw-ts 3990002004)
    (cairn:record-event db "Pp" "task.fork" '(:child-id "Cc" :edge-type "phase-of")
                        :raw-ts 3990002005)
    (is (string= "Pp" (task-parent db "Cc")))
    (cairn:record-event db "Pp" "task.sever" '(:target-id "Cc" :edge-type "phase-of")
                        :raw-ts 3990002006)
    (is (null (task-parent db "Cc")))))

(test edge-upsert-is-idempotent-and-self-loops-are-rejected
  "Re-linking the same edge adds no row; the CHECK forbids a self-loop."
  (with-event-store (db)
    (cairn:record-event db "X" "task.create" '() :raw-ts 3990003000)
    (cairn:record-event db "X" "task.link" '(:target-id "Y" :edge-type "depends-on")
                        :raw-ts 3990003001)
    (let ((n (sqlite:execute-single db "SELECT count(*) FROM edges")))
      (cairn:record-event db "X" "task.link" '(:target-id "Y" :edge-type "depends-on")
                          :raw-ts 3990003002)
      (is (= n (sqlite:execute-single db "SELECT count(*) FROM edges"))))
    (let ((id (sqlite:execute-single db "SELECT id FROM tasks WHERE slug = 'X'")))
      (signals sqlite:sqlite-error
        (sqlite:execute-non-query db
          "INSERT INTO edges(src_id, dst_id, type, created_ts) VALUES(?, ?, 'related', 1)"
          id id)))))

(test rebuild-reproduces-projections-byte-identically
  "Projections are a pure function of the log: a full rebuild leaves the
projection digest unchanged, and verify confirms it."
  (with-event-store (db)
    (cairn:record-event db "P" "task.create" '(:description "p") :raw-ts 3990004000)
    (cairn:record-event db "P" "task.fork" '(:child-id "A" :edge-type "phase-of")
                        :raw-ts 3990004001)
    (cairn:record-event db "A" "observation" '(:text "alpha note") :raw-ts 3990004002)
    (cairn:record-event db "P" "task.update-status" '(:status "completed")
                        :raw-ts 3990004003)
    (cairn:record-event db "P" "handoff.create" '(:path "/h.md" :summary "done")
                        :raw-ts 3990004004)
    (let ((before (cairn::%projection-digest db)))
      (cairn:rebuild db)
      (is (string= before (cairn::%projection-digest db)))
      (is (cairn:verify db)))))

(test identical-events-collapse-to-one
  "Two events with identical content fold to a single row."
  (with-event-store (db)
    (cairn:record-event db "t" "observation" '(:text "dup") :session "s" :raw-ts 3990000000)
    (is (null (cairn:record-event db "t" "observation" '(:text "dup")
                                  :session "s" :raw-ts 3990000000)))
    (is (= 1 (sqlite:execute-single db "SELECT count(*) FROM observations WHERE text = 'dup'")))
    (is (= 1 (sqlite:execute-single db "SELECT count(*) FROM events WHERE type = 'observation'")))))

(test handoff-creates-row-and-mirrors-an-observation
  "A handoff writes its row and an observation mirror searchable in the feed."
  (with-event-store (db)
    (cairn:record-event db "t" "task.create" '() :raw-ts 3990000000)
    (cairn:record-event db "t" "handoff.create" '(:path "/h/x.md" :summary "shipped")
                        :raw-ts 3990000001)
    (is (equal '(("/h/x.md" "shipped"))
               (sqlite:execute-to-list db "SELECT path, summary FROM handoffs")))
    (is (equal '(("Handoff: shipped → /h/x.md"))
               (sqlite:execute-to-list db
                 "SELECT text FROM observations WHERE text LIKE 'Handoff:%'")))))

(test write-boundary-invariants-hold
  "Namespace prefixes split off, timestamps canonicalize into the universal-time
window, and edges only carry the closed enum."
  (with-event-store (db)
    (cairn:record-event db "kleisli:legacy-qualified-task" "task.create" '()
                        :raw-ts 1700000000)
    (cairn:record-event db "plain" "task.link" '(:target-id "other" :edge-type "blocks")
                        :raw-ts 3990000000)
    (is (zerop (sqlite:execute-single db "SELECT count(*) FROM tasks WHERE slug LIKE '%:%'")))
    (is (string= "kleisli"
                 (sqlite:execute-single db
                   "SELECT depot FROM tasks WHERE slug = 'legacy-qualified-task'")))
    (is (zerop (sqlite:execute-single db
                 "SELECT count(*) FROM events WHERE ts < 3786825600 OR ts > 4102444800")))
    (is (zerop (sqlite:execute-single db
                 "SELECT count(*) FROM edges
                   WHERE type NOT IN ('phase-of', 'depends-on', 'related')")))))

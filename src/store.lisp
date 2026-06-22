(in-package #:kli/cairn)

(define-condition cairn-store-error (error) ())

(define-condition cairn-store-missing-fts5 (cairn-store-error)
  ()
  (:report (lambda (c stream)
             (declare (ignore c))
             (format stream
                     "The linked SQLite library was built without FTS5 ~
                      (ENABLE_FTS5 absent from PRAGMA compile_options); ~
                      the store requires full-text search."))))

(defun %sqlite-foreign-library-loaded-p ()
  "True once the binding's foreign library has been opened. The library symbol
is internal to its package, hence the internal reference."
  (cffi:foreign-library-loaded-p 'sqlite-ffi::sqlite3-lib))

(defun %compile-options (db)
  (mapcar #'first (sqlite:execute-to-list db "PRAGMA compile_options")))

(defun %assert-fts5 (db)
  (unless (member "ENABLE_FTS5" (%compile-options db) :test #'string=)
    (error 'cairn-store-missing-fts5)))

(defparameter +schema-version+ "1")

(defparameter +schema-statements+
  (list
   "CREATE TABLE IF NOT EXISTS schema_meta (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )"
   ;; Append-only log; the single source of truth. seq orders replay, event_key
   ;; dedups (INSERT OR IGNORE), event_id is the portable ULID stable id.
   "CREATE TABLE IF NOT EXISTS events (
      seq             INTEGER PRIMARY KEY AUTOINCREMENT,
      event_key       TEXT NOT NULL,
      event_id        TEXT NOT NULL,
      task_id         TEXT,
      type            TEXT NOT NULL,
      ts              INTEGER NOT NULL,
      session_id      TEXT,
      prev_session_id TEXT,
      vector_clock    TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(vector_clock)),
      data            TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(data)),
      legacy_id       TEXT,
      source_seq      INTEGER,
      imported_at     INTEGER
    )"
   "CREATE UNIQUE INDEX IF NOT EXISTS events_key_uq ON events(event_key)"
   "CREATE INDEX IF NOT EXISTS events_task_idx ON events(task_id, seq)"
   "CREATE INDEX IF NOT EXISTS events_type_idx ON events(type, seq)"
   ;; Backs the portable replay order: rebuild folds the log by (ts, event_id),
   ;; independent of the local AUTOINCREMENT seq.
   "CREATE INDEX IF NOT EXISTS events_replay_idx ON events(ts, event_id)"
   ;; Materialized projection. parent_task_id + prev_phase_id are the two FKs
   ;; that carry the fibration; everything else is a derived view of events.
   "CREATE TABLE IF NOT EXISTS tasks (
      id             INTEGER PRIMARY KEY,
      slug           TEXT NOT NULL UNIQUE,
      depot          TEXT,
      parent_task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL,
      prev_phase_id  INTEGER REFERENCES tasks(id) ON DELETE SET NULL,
      status         TEXT NOT NULL DEFAULT 'open'
                       CHECK (status IN ('open','active','completed','abandoned','blocked')),
      description    TEXT NOT NULL DEFAULT '',
      created_ts     INTEGER NOT NULL,
      updated_ts     INTEGER NOT NULL,
      status_ts      INTEGER,
      description_ts INTEGER,
      has_events     INTEGER NOT NULL DEFAULT 1,
      project_id     TEXT
    )"
   "CREATE INDEX IF NOT EXISTS tasks_parent_idx ON tasks(parent_task_id)"
   "CREATE INDEX IF NOT EXISTS tasks_prev_idx   ON tasks(prev_phase_id)"
   "CREATE INDEX IF NOT EXISTS tasks_status_idx ON tasks(status)"
   ;; Lateral relations the two task FKs do not carry. Closed enum + free tag;
   ;; the UNIQUE index makes re-emitted edges idempotent.
   "CREATE TABLE IF NOT EXISTS edges (
      id         INTEGER PRIMARY KEY,
      src_id     INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
      dst_id     INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
      type       TEXT NOT NULL CHECK (type IN ('phase-of','depends-on','related')),
      tag        TEXT,
      created_ts INTEGER NOT NULL,
      CHECK (src_id <> dst_id)
    )"
   "CREATE UNIQUE INDEX IF NOT EXISTS edges_uq ON edges(src_id, dst_id, type, IFNULL(tag,''))"
   "CREATE INDEX IF NOT EXISTS edges_dst_idx ON edges(dst_id, type)"
   ;; obs_id is an INTEGER rowid alias: it is the FTS5 external-content
   ;; content_rowid. event_id (the ULID) is the de-dup / provenance key.
   "CREATE TABLE IF NOT EXISTS observations (
      obs_id   INTEGER PRIMARY KEY,
      event_id TEXT UNIQUE,
      task_id  INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
      text     TEXT NOT NULL,
      ts       INTEGER NOT NULL
    )"
   "CREATE INDEX IF NOT EXISTS obs_task_idx ON observations(task_id, ts)"
   ;; tokenchars/prefix keep identifiers and file:line spans whole; no porter,
   ;; no stopwords.
   "CREATE VIRTUAL TABLE IF NOT EXISTS obs_fts USING fts5(
      text,
      content='observations',
      content_rowid='obs_id',
      tokenize='unicode61 remove_diacritics 0 tokenchars ''_:-.''',
      prefix='2 3'
    )"
   "CREATE TRIGGER IF NOT EXISTS obs_fts_ai AFTER INSERT ON observations BEGIN
      INSERT INTO obs_fts(rowid, text) VALUES (new.obs_id, new.text);
    END"
   "CREATE TRIGGER IF NOT EXISTS obs_fts_ad AFTER DELETE ON observations BEGIN
      INSERT INTO obs_fts(obs_fts, rowid, text) VALUES('delete', old.obs_id, old.text);
    END"
   "CREATE TRIGGER IF NOT EXISTS obs_fts_au AFTER UPDATE ON observations BEGIN
      INSERT INTO obs_fts(obs_fts, rowid, text) VALUES('delete', old.obs_id, old.text);
      INSERT INTO obs_fts(rowid, text) VALUES (new.obs_id, new.text);
    END"
   "CREATE TABLE IF NOT EXISTS handoffs (
      id       INTEGER PRIMARY KEY,
      event_id TEXT,
      task_id  INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
      path     TEXT NOT NULL,
      summary  TEXT NOT NULL DEFAULT '',
      ts       INTEGER NOT NULL
    )"
   "CREATE INDEX IF NOT EXISTS handoff_task_idx ON handoffs(task_id, ts)"
   "CREATE TABLE IF NOT EXISTS task_metadata (
      task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
      key     TEXT NOT NULL,
      value   TEXT,
      ts      INTEGER NOT NULL,
      PRIMARY KEY (task_id, key)
    )"
   "CREATE TABLE IF NOT EXISTS artifacts (
      id      INTEGER PRIMARY KEY,
      task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
      path    TEXT NOT NULL,
      kind    TEXT,
      ts      INTEGER NOT NULL,
      UNIQUE (task_id, path)
    )"
   "CREATE TABLE IF NOT EXISTS projects (
      project_id   TEXT PRIMARY KEY,
      root_path    TEXT,
      display_name TEXT NOT NULL,
      created_at   INTEGER NOT NULL,
      source       TEXT NOT NULL
    )"
   ;; Model-defined query vocabulary, folded from view.define/view.undefine
   ;; events. The user layer the resolver lays over the in-code built-in views.
   "CREATE TABLE IF NOT EXISTS named_views (
      name  TEXT PRIMARY KEY,
      query TEXT NOT NULL,
      ts    INTEGER NOT NULL
    )")
  "Idempotent DDL applied once on every store-open.")

(defun %table-columns (db table)
  "The column names of TABLE."
  (mapcar #'second
          (sqlite:execute-to-list db (format nil "PRAGMA table_info(~A)" table))))

(defun %ensure-column (db table column type)
  "Add COLUMN of TYPE to TABLE when absent. SQLite has no ADD COLUMN IF NOT
EXISTS, so the column set is checked first; this carries a store predating the
column forward without a rebuild. Idempotent."
  (unless (member column (%table-columns db table) :test #'string=)
    (sqlite:execute-non-query db
      (format nil "ALTER TABLE ~A ADD COLUMN ~A ~A" table column type))))

(defun apply-schema (db)
  "Create every table, index, trigger, and the FTS index if absent, and stamp
the schema version. Idempotent."
  (sqlite:with-transaction db
    (dolist (stmt +schema-statements+)
      (sqlite:execute-non-query db stmt))
    (%ensure-column db "tasks" "description_ts" "INTEGER")
    (sqlite:execute-non-query
     db "INSERT OR IGNORE INTO schema_meta(key, value) VALUES('schema_version', ?)"
     +schema-version+))
  db)

(defun open-cairn-store (path)
  "Open the store at PATH and return the SQLite handle. Opens at call time.
Enables WAL journaling, foreign-key enforcement, and a busy timeout, refuses to
run against a SQLite without FTS5, and applies the schema. The half-open
connection is closed before any error propagates."
  (let ((db (sqlite:connect path)))
    (handler-bind
        ((error (lambda (c)
                  (declare (ignore c))
                  (ignore-errors (sqlite:disconnect db)))))
      (sqlite:execute-non-query db "PRAGMA foreign_keys = ON")
      (sqlite:execute-non-query db "PRAGMA busy_timeout = 5000")
      (sqlite:execute-non-query db "PRAGMA synchronous = NORMAL")
      (let ((mode (sqlite:execute-single db "PRAGMA journal_mode = WAL")))
        (unless (and (stringp mode) (string-equal mode "wal"))
          (error 'cairn-store-error)))
      (%assert-fts5 db)
      (apply-schema db))
    db))

(defun close-cairn-store (db)
  "Disconnect the store handle DB."
  (sqlite:disconnect db))

(defun ensure-project-row (db project)
  "Upsert the projects row for PROJECT. Idempotent; created_at is preserved
across re-opens. Returns PROJECT."
  (sqlite:execute-non-query db
    "INSERT INTO projects(project_id, root_path, display_name, created_at, source)
     VALUES(?,?,?,?,?)
     ON CONFLICT(project_id) DO UPDATE SET
       root_path = excluded.root_path,
       display_name = excluded.display_name,
       source = excluded.source"
    (cp-project-id project) (cp-root-path project) (cp-display-name project)
    (get-universal-time) (cp-source project))
  project)

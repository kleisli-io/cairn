(in-package #:kli/cairn/tests)
(in-suite all)

;;; Project discovery, the resolution ladder, project identity, and the store's
;;; project registration. Shares temp-root/make-test-dir/with-cairn-protocol
;;; from the store suite.

(defun install-config-stack (context)
  (install-extension context obj:*standard-object-extension-manifest*)
  (install-extension context event:*events-extension-manifest*)
  (install-extension context config:*config-extension-manifest*))

(defun write-global-settings (global-dir json)
  "Write JSON as the global settings file under GLOBAL-DIR."
  (let ((path (merge-pathnames "settings.json"
                               (ensure-directories-exist global-dir))))
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create :external-format :utf-8)
      (write-string json out))
    path))

;;; --- Resolution ladder ---

(test override-outranks-a-project-directory
  "The *CAIRN-DB-PATH* override beats a present project directory."
  (let* ((root (temp-root))
         (project (make-test-dir root "proj"))
         (override (merge-pathnames "override.db" (make-test-dir root "o"))))
    (make-test-dir project ".kli")
    (let ((cairn:*cairn-db-path* override)
          (config:*project-start-directory* project))
      (multiple-value-bind (path step) (cairn:resolve-cairn-db-location)
        (is (eq :override step))
        (is (equal (namestring override) (namestring path)))))))

(test db-path-setting-outranks-data-dir
  "With both settings present, dbPath wins over dataDir."
  (let* ((root (temp-root))
         (global (make-test-dir root "global"))
         (start (make-test-dir root "start"))
         (data (make-test-dir root "data"))
         (explicit (merge-pathnames "explicit.db" (make-test-dir root "x"))))
    (write-global-settings
     global
     (format nil "{\"cairn\":{\"dbPath\":~S,\"dataDir\":~S}}"
             (namestring explicit) (namestring data)))
    (let ((cairn:*cairn-db-path* nil)
          (config:*global-config-dir* global)
          (config:*project-start-directory* start)
          (context (kli:make-kernel-host)))
      (switch-to-extension-protocol context)
      (install-config-stack context)
      (multiple-value-bind (path step) (cairn:resolve-cairn-db-location context)
        (is (eq :db-path step))
        (is (equal (namestring explicit) (namestring path)))))))

(test data-dir-setting-resolves-under-it
  "The dataDir setting resolves to <dataDir>/cairn.db."
  (let* ((root (temp-root))
         (global (make-test-dir root "global"))
         (start (make-test-dir root "start"))
         (data (make-test-dir root "data")))
    (write-global-settings
     global (format nil "{\"cairn\":{\"dataDir\":~S}}" (namestring data)))
    (let ((cairn:*cairn-db-path* nil)
          (config:*global-config-dir* global)
          (config:*project-start-directory* start)
          (context (kli:make-kernel-host)))
      (switch-to-extension-protocol context)
      (install-config-stack context)
      (multiple-value-bind (path step) (cairn:resolve-cairn-db-location context)
        (is (eq :data-dir step))
        (is (equal (namestring (merge-pathnames "cairn.db" data))
                   (namestring path)))))))

(test scratch-walk-resolves-under-the-data-home
  "With no override, no setting, and no project or repository marker up to the
filesystem root, resolution falls through to the user data home."
  (let* ((root (temp-root))
         (start (make-test-dir root "scratch-cwd")))
    (let ((cairn:*cairn-db-path* nil)
          (config:*project-start-directory* start))
      (multiple-value-bind (path step) (cairn:resolve-cairn-db-location)
        (is (eq :global step))
        (is (equal (namestring (uiop:xdg-data-home "kli/" "cairn.db"))
                   (namestring path)))))))

;;; --- Bounded walk ---

(test walk-stops-at-the-repo-root-not-an-ancestor-project
  "The walk stops at the first repository root and never climbs to an ancestor
project directory beyond it."
  (let* ((root (temp-root))
         (outer (make-test-dir root "outer"))
         (repo (make-test-dir outer "repo"))
         (sub (make-test-dir repo "sub")))
    (make-test-dir outer ".kli")
    (make-test-dir repo ".git")
    (let ((config:*project-start-directory* sub))
      (is (null (cairn:project-cairn-dir))
          "the .git boundary blocks the climb to the ancestor .kli"))))

(test nearest-project-dir-shadows-an-ancestor
  "A nested project directory shadows an ancestor's."
  (let* ((root (temp-root))
         (project (make-test-dir root "proj"))
         (sub (make-test-dir project "sub")))
    (make-test-dir project ".kli")
    (make-test-dir sub ".kli")
    (let ((config:*project-start-directory* sub))
      (is (search "sub" (namestring (cairn:project-cairn-dir)))
          "the nearest project directory wins"))))

;;; --- Project identity ---

(test scratch-when-no-project-markers
  "Outside any project or repository the resolved project is scratch."
  (let* ((root (temp-root))
         (start (make-test-dir root "lonely")))
    (let ((config:*project-start-directory* start))
      (let ((project (cairn:resolve-project)))
        (is (string= cairn:+scratch-project-id+ (cairn:cp-project-id project)))
        (is (string= "scratch" (cairn:cp-source project)))
        (is (null (cairn:cp-root-path project)))))))

(test kli-dir-yields-a-content-addressed-project-id
  "A project directory yields a content-addressed id over its parent root."
  (let* ((root (temp-root))
         (project (make-test-dir root "proj")))
    (make-test-dir project ".kli")
    (let ((config:*project-start-directory* project))
      (let ((resolved (cairn:resolve-project)))
        (is (string= "kli-dir" (cairn:cp-source resolved)))
        (is (string= (cairn:derive-project-id project)
                     (cairn:cp-project-id resolved)))
        (is (string= "proj" (cairn:cp-display-name resolved)))))))

(test project-id-is-stable-and-distinct-per-root
  "DERIVE-PROJECT-ID is deterministic per root and distinct across roots."
  (let* ((root (temp-root))
         (a (make-test-dir root "a"))
         (b (make-test-dir root "b")))
    (is (string= (cairn:derive-project-id a) (cairn:derive-project-id a)))
    (is (not (string= (cairn:derive-project-id a) (cairn:derive-project-id b))))
    (is (eql 0 (search "proj-" (cairn:derive-project-id a))))
    (is (= 17 (length (cairn:derive-project-id a))))))

(test repo-root-yields-a-project-id
  "A bare repository root (no project directory) yields a repo-sourced id."
  (let* ((root (temp-root))
         (repo (make-test-dir root "repo"))
         (sub (make-test-dir repo "sub")))
    (make-test-dir repo ".git")
    (let ((config:*project-start-directory* sub))
      (let ((resolved (cairn:resolve-project)))
        (is (string= "repo" (cairn:cp-source resolved)))
        (is (string= (cairn:derive-project-id repo)
                     (cairn:cp-project-id resolved)))))))

(test explicit-project-id-setting-wins
  "An explicit projectId setting outranks the content-addressed derivation."
  (let* ((root (temp-root))
         (global (make-test-dir root "global"))
         (project (make-test-dir root "proj")))
    (make-test-dir project ".kli")
    (write-global-settings global "{\"cairn\":{\"projectId\":\"my-id\"}}")
    (let ((config:*global-config-dir* global)
          (config:*project-start-directory* project)
          (context (kli:make-kernel-host)))
      (switch-to-extension-protocol context)
      (install-config-stack context)
      (let ((resolved (cairn:resolve-project context)))
        (is (string= "my-id" (cairn:cp-project-id resolved)))
        (is (string= "setting" (cairn:cp-source resolved)))))))

;;; --- Store registration + gitignore ---

(test open-registers-the-scratch-project
  "Opening a scratch store records a scratch projects row and stashes the id."
  (with-cairn-protocol (context protocol)
    (let ((db (ext:protocol-storage protocol cairn:+cairn-db-key+)))
      (is (equal cairn:+scratch-project-id+
                 (sqlite:execute-single
                  db "SELECT project_id FROM projects WHERE source = 'scratch'"))
          "a scratch projects row exists after open")
      (is (equal cairn:+scratch-project-id+ (cairn:current-project-id context))
          "the resolved project id is stashed per protocol"))))

(test created-task-carries-the-project-id-and-survives-rebuild
  "A created task is stamped with the resolved project id, and the id is in the
event log so a rebuild reproduces it."
  (with-cairn-protocol (context protocol)
    (let ((db (ext:protocol-storage protocol cairn:+cairn-db-key+)))
      (cairn::run-task-create nil (list :name "locality probe task") context)
      (let ((slug (cairn:current-task-id context)))
        (is (equal cairn:+scratch-project-id+
                   (sqlite:execute-single
                    db "SELECT project_id FROM tasks WHERE slug = ?" slug)))
        (cairn:rebuild db)
        (is (equal cairn:+scratch-project-id+
                   (sqlite:execute-single
                    db "SELECT project_id FROM tasks WHERE slug = ?" slug))
            "the project id replays from the event log")))))

(test gitignore-guard-ignores-the-database-and-is-idempotent
  "The project-local gitignore guard adds the database glob exactly once."
  (let* ((root (temp-root))
         (kli-dir (make-test-dir root "proj" ".kli"))
         (db-path (merge-pathnames "cairn.db" kli-dir)))
    (cairn:ensure-db-gitignore db-path)
    (cairn:ensure-db-gitignore db-path)
    (let ((lines (uiop:read-file-lines (merge-pathnames ".gitignore" kli-dir))))
      (is (= 1 (count "cairn.db*" lines :test #'string=))
          "the database glob is present exactly once"))))

(in-package #:kli/cairn)

(defparameter +cairn-data-subdir+ "kli/"
  "Data-home subdirectory shared with the kli namespace.")

(defparameter +cairn-db-filename+ "cairn.db"
  "Default database filename.")

(defparameter +cairn-settings-section+ "cairn")
(defparameter +cairn-db-path-setting+ "dbPath")
(defparameter +cairn-data-dir-setting+ "dataDir")
(defparameter +cairn-project-id-setting+ "projectId")

(defparameter +cairn-project-dirname+ ".kli/"
  "Project-local store directory, kli's standard project home.")

(defparameter +scratch-project-id+ "scratch"
  "Reserved project id for work outside any project root.")

(defvar *cairn-db-path* nil
  "Override for the database file. NIL resolves through the configured settings,
then the project directory, then the user data home.")

(defun cairn-data-home ()
  "User-global data directory: $XDG_DATA_HOME/kli/ or ~/.local/share/kli/.
Outside any repository."
  (uiop:xdg-data-home +cairn-data-subdir+))

(defun cairn-setting (context name)
  "The non-empty string value of the NAME setting under the cairn section, or
NIL when no config service or setting is present."
  (let* ((service (and context (find-config-service context)))
         (settings (and service (config-service-settings service))))
    (when settings
      (let ((raw (settings-value settings +cairn-settings-section+ name)))
        (when (and (stringp raw) (plusp (length raw))) raw)))))

(defun cairn-db-path-from-settings (context)
  "The dbPath setting expanded to an absolute path, or NIL."
  (let ((raw (cairn-setting context +cairn-db-path-setting+)))
    (when raw (expand-config-path raw))))

(defun cairn-db-path-from-data-dir (context)
  "The database under the dataDir setting, expanded as a directory, or NIL."
  (let ((raw (cairn-setting context +cairn-data-dir-setting+)))
    (when raw
      (merge-pathnames +cairn-db-filename+ (expand-config-path raw :directory t)))))

;;; Project discovery walks ancestors from the start directory, stopping at the
;;; first project or repository marker so it never climbs past a repository root
;;; into an unrelated parent.

(defun cairn-project-start ()
  "Where the project walk-up begins: the configured start, else the cwd."
  (or *project-start-directory* (uiop:getcwd)))

(defun %git-root-p (dir)
  "True when DIR holds .git as a directory or a file (worktrees)."
  (let ((marker (merge-pathnames ".git" dir)))
    (and (or (uiop:directory-exists-p marker) (uiop:file-exists-p marker)) t)))

(defun %project-dir-at (dir)
  "The project directory under DIR, or NIL."
  (let ((marker (merge-pathnames +cairn-project-dirname+ dir)))
    (or (uiop:directory-exists-p marker) (uiop:file-exists-p marker))))

(defun project-cairn-dir (&key (start (cairn-project-start)))
  "The nearest project directory at or above START. The walk stops at the first
project or repository marker, never escaping to the filesystem root; NIL when no
project directory precedes the bound."
  (dolist (dir (directory-ancestors start) nil)
    (let ((found (%project-dir-at dir)))
      (when found (return found)))
    (when (%git-root-p dir) (return nil))))

(defun project-repo-root (&key (start (cairn-project-start)))
  "The nearest repository root at or above START, or NIL."
  (dolist (dir (directory-ancestors start) nil)
    (when (%git-root-p dir) (return dir))))

(defun cairn-db-path-from-project ()
  "The database under the nearest project directory, or NIL outside a project."
  (let ((dir (project-cairn-dir)))
    (when dir
      (merge-pathnames +cairn-db-filename+ (uiop:ensure-directory-pathname dir)))))

(defun resolve-cairn-db-location (&optional context)
  "Resolve the database path and the step that won, highest precedence first:
:override, :db-path, :data-dir, :project, :global."
  (let (path)
    (cond
      ((setf path *cairn-db-path*) (values path :override))
      ((setf path (cairn-db-path-from-settings context)) (values path :db-path))
      ((setf path (cairn-db-path-from-data-dir context)) (values path :data-dir))
      ((setf path (cairn-db-path-from-project)) (values path :project))
      (t (values (merge-pathnames +cairn-db-filename+ (cairn-data-home)) :global)))))

(defun resolve-cairn-db-path (&optional context)
  "The resolved database path; see RESOLVE-CAIRN-DB-LOCATION for precedence."
  (values (resolve-cairn-db-location context)))

;;; Project identity. The id is content-addressed over the canonical project
;;; root path, so it is stable across the working directory within a project and
;;; never a truncated bucket of a name.

(defstruct (cairn-project (:conc-name cp-))
  (project-id +scratch-project-id+ :read-only t)
  (root-path nil :read-only t)
  (display-name +scratch-project-id+ :read-only t)
  (source "scratch" :read-only t))

(defun %canonical-root-namestring (root)
  "ROOT's canonical absolute directory path, for content addressing."
  (uiop:native-namestring (uiop:ensure-directory-pathname (truename root))))

(defun %root-display-name (root)
  "ROOT's basename for display."
  (or (car (last (pathname-directory (uiop:ensure-directory-pathname root))))
      +scratch-project-id+))

(defun derive-project-id (root)
  "A content-addressed id over ROOT's canonical path: proj-<first 12 hex of
sha256>."
  (concatenate 'string "proj-"
               (subseq (ironclad:byte-array-to-hex-string
                        (ironclad:digest-sequence
                         :sha256
                         (sb-ext:string-to-octets (%canonical-root-namestring root)
                                                  :external-format :utf-8)))
                       0 12)))

(defun project-root-and-source ()
  "The nearest project root directory and its source tag. The parent of a
project directory (\"kli-dir\"), else the repository root (\"repo\"), else NIL
and \"scratch\"."
  (let ((dir (project-cairn-dir)))
    (if dir
        (values (uiop:pathname-parent-directory-pathname
                 (uiop:ensure-directory-pathname dir))
                "kli-dir")
        (let ((repo (project-repo-root)))
          (if repo (values repo "repo") (values nil "scratch"))))))

(defun resolve-project (&optional context)
  "Resolve the active project identity from settings and the filesystem.
Priority: an explicit projectId setting; else a content-addressed id over the
nearest project root; else the reserved scratch id."
  (let ((explicit (cairn-setting context +cairn-project-id-setting+)))
    (if explicit
        (make-cairn-project :project-id explicit :display-name explicit
                            :source "setting")
        (multiple-value-bind (root source) (project-root-and-source)
          (if root
              (make-cairn-project :project-id (derive-project-id root)
                                  :root-path (%canonical-root-namestring root)
                                  :display-name (%root-display-name root)
                                  :source source)
              (make-cairn-project))))))

(defun ensure-db-gitignore (db-path)
  "Ensure the project-local store directory ignores the binary database files
while keeping the committable markdown scratchpad tracked. Idempotent."
  (let* ((dir (uiop:pathname-directory-pathname db-path))
         (ignore (merge-pathnames ".gitignore" dir))
         (entry "cairn.db*"))
    (unless (and (uiop:file-exists-p ignore)
                 (member entry (uiop:read-file-lines ignore) :test #'string=))
      (with-open-file (out ignore :direction :output
                                  :if-exists :append :if-does-not-exist :create)
        (write-line entry out)))))

(defun ensure-log-gitattributes (db-path)
  "Ensure the store directory union-merges the per-task event logs, so appends
from parallel writers combine instead of conflicting. The logs are a deduped,
order-independent fold, so the union of two sides is the correct merge.
Idempotent."
  (let* ((dir (uiop:pathname-directory-pathname db-path))
         (attrs (merge-pathnames ".gitattributes" dir))
         (entry "tasks/**/events.ndjson merge=union"))
    (unless (and (uiop:file-exists-p attrs)
                 (member entry (uiop:read-file-lines attrs) :test #'string=))
      (with-open-file (out attrs :direction :output
                                 :if-exists :append :if-does-not-exist :create)
        (write-line entry out)))))

;;; Markdown scratchpad: the model's research/plan/handoff notes live beside the
;;; database under tasks/<slug>/, sharing the database's parent so store and
;;; scratchpad never diverge. The directory is created when a task records its
;;; first event — the event log lives here — so a task seen only as a reference
;;; target, with no event of its own, gets no directory.

(defun cairn-db-parent (&optional context)
  "The directory holding the resolved database file."
  (uiop:pathname-directory-pathname (resolve-cairn-db-path context)))

(defun cairn-tasks-root (&optional context)
  "The tasks/ scratchpad root beside the database."
  (merge-pathnames "tasks/" (cairn-db-parent context)))

(defun cairn-task-directory (slug &optional context)
  "The scratchpad directory for SLUG."
  (merge-pathnames (concatenate 'string slug "/") (cairn-tasks-root context)))

(defun cairn-task-log-under (base-dir slug)
  "SLUG's event log under BASE-DIR: tasks/<slug>/events.ndjson. The single source
of the on-disk layout, shared by the resolved path and the write-path mirror."
  (merge-pathnames (concatenate 'string "tasks/" slug "/events.ndjson")
                   (uiop:ensure-directory-pathname base-dir)))

(defun cairn-task-log-path (slug &optional context)
  "SLUG's append-only event log: tasks/<slug>/events.ndjson beside the database."
  (cairn-task-log-under (cairn-db-parent context) slug))

(defun cairn-handoffs-dir (slug &optional context)
  "The handoffs/ subdirectory of SLUG's scratchpad."
  (merge-pathnames "handoffs/" (cairn-task-directory slug context)))

(defun cairn-handoff-path (slug filename &optional context)
  "The full path of handoff FILENAME under SLUG's handoffs directory."
  (merge-pathnames filename (cairn-handoffs-dir slug context)))

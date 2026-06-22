(in-package #:kli/cairn/tests)
(in-suite all)

;;; Bounded authority per seam, never the lattice top: the install principal
;;; for loads/retracts, cairn's own tool caps for tool calls.
(defmacro with-extension-load-authority (&body body)
  `(let ((ext:*call-subject* ext:*install-subject*))
     ,@body))

(defmacro with-cairn-tool-authority (&body body)
  `(let ((ext:*call-subject*
           (ext:make-subject
            :capabilities '(:cairn/read :cairn/write :cairn/observe))))
     ,@body))

(defvar *cairn-test-counter* 0)

(defun temp-root ()
  (truename
   (ensure-directories-exist
    (merge-pathnames (format nil "cairn-test-~D-~D/"
                             (get-universal-time)
                             (incf *cairn-test-counter*))
                     #p"/tmp/"))))

(defun make-test-dir (root &rest components)
  (let ((dir (if components
                 (merge-pathnames (format nil "~{~A/~}" components) root)
                 root)))
    (ensure-directories-exist dir)
    dir))

(defun switch-to-extension-protocol (context)
  (with-extension-load-authority
    (let* ((boot (kli:active-protocol context))
           (protocol (kli:install-protocol boot
                                           (ext:make-extension-protocol)
                                           context)))
      (kli:switch-protocol boot (kli:object-id protocol) context)
      protocol)))

(defun install-extension (context manifest)
  (with-extension-load-authority
    (ext:install-manifest manifest (kli:active-protocol context) context)))

(defmacro with-cairn-protocol ((context-var protocol-var
                                &key (root-var (gensym "ROOT"))
                                     (cairn-var (gensym "CAIRN")))
                               &body body)
  "A fresh context whose extension protocol has events, config, and cairn
installed. CAIRN-VAR is bound to the installed cairn extension handle. The
database path is pinned under a private temp root so the test never touches a
real store."
  `(let* ((,root-var (temp-root))
          (,context-var (kli:make-kernel-host))
          (,protocol-var (switch-to-extension-protocol ,context-var)))
     (let ((config:*global-config-dir* (make-test-dir ,root-var "global"))
           (config:*project-start-directory* (make-test-dir ,root-var "proj"))
           (cairn:*cairn-db-path*
             (merge-pathnames "cairn.db" (make-test-dir ,root-var "db"))))
       (install-extension ,context-var obj:*standard-object-extension-manifest*)
       (install-extension ,context-var event:*events-extension-manifest*)
       (install-extension ,context-var config:*config-extension-manifest*)
       (let ((,cairn-var
               (install-extension ,context-var
                                  cairn:*cairn-extension-manifest*)))
         (declare (ignorable ,cairn-var))
         (with-cairn-tool-authority ,@body)))))

(test store-handle-reachable-through-protocol-storage
  "Installing the store opens a database whose handle lives in protocol storage,
not in any image-global variable."
  (with-cairn-protocol (context protocol)
    (let ((handle (ext:protocol-storage protocol cairn:+cairn-db-key+)))
      (is (not (null handle))
          "the handle is reachable via protocol-storage")
      (is (eq handle (gethash cairn:+cairn-db-key+
                              (ext:protocol-storage-table protocol)))
          "the handle is keyed in the protocol's own storage table")
      (is (= 1 (sqlite:execute-single handle "SELECT 1"))
          "the stored handle is a live, queryable connection"))))

(test deactivate-closes-the-database
  "Deactivating the extension closes the database; a query on the closed handle
errors, and the storage key is drained."
  (with-cairn-protocol (context protocol :cairn-var cairn-handle)
    (let ((handle (ext:protocol-storage protocol cairn:+cairn-db-key+)))
      (is (not (null handle)))
      (with-extension-load-authority
        (ext:deactivate-extension protocol cairn-handle context))
      (is (null (ext:protocol-storage protocol cairn:+cairn-db-key+))
          "deactivation drains the stored handle")
      (signals error
        (sqlite:execute-single handle "SELECT 1")))))

(test effect-cannot-be-constructed-without-a-retractor
  "An effect contribution requires both an installer and a retractor."
  (signals error
    (ext:make-effect-contribution :name :cairn-store-db
                                  :installer #'cairn::cairn-open-db
                                  :retractor nil)))

(test two-protocols-hold-distinct-handles
  "Two independently installed protocols hold two distinct database handles."
  (with-cairn-protocol (context-a protocol-a)
    (with-cairn-protocol (context-b protocol-b)
      (let ((handle-a (ext:protocol-storage protocol-a cairn:+cairn-db-key+))
            (handle-b (ext:protocol-storage protocol-b cairn:+cairn-db-key+)))
        (is (not (null handle-a)))
        (is (not (null handle-b)))
        (is (not (eq handle-a handle-b))
            "each protocol opened its own connection")))))

(test xdg-resolution-when-unconfigured
  "With no override, no setting, and no project, the path resolves under the
user data home, never the task store."
  (let ((cairn:*cairn-db-path* nil)
        (config:*project-start-directory*
          (truename (ensure-directories-exist #p"/tmp/cairn-no-project/"))))
    (let ((path (cairn:resolve-cairn-db-path)))
      (is (equal (namestring (uiop:xdg-data-home "kli/" "cairn.db"))
                 (namestring path))
          "resolves under xdg-data-home/kli")
      (is (null (search "tasks" (namestring path)))
          "never resolves into a sibling subdirectory"))))

(test project-local-resolution-inside-a-repo
  "Inside a directory with a project configuration directory, the path resolves
project-local rather than under the user data home."
  (let* ((root (temp-root))
         (project (make-test-dir root "repo"))
         (config-dir (make-test-dir project ".kli")))
    (declare (ignore config-dir))
    (let ((cairn:*cairn-db-path* nil)
          (config:*project-start-directory* project))
      (let ((path (cairn:resolve-cairn-db-path)))
        (is (eql 0 (search (namestring project) (namestring path)))
            "the path is under the project directory")
        (is (search ".kli" (namestring path))
            "the path is inside the project configuration directory")
        (is (null (search "tasks" (namestring path)))
            "never resolves into a task subdirectory")))))

(test fts5-is-compiled-in
  "The linked SQLite reports FTS5, which the store asserts at open."
  (let ((db (sqlite:connect ":memory:")))
    (unwind-protect
         (is (member "ENABLE_FTS5"
                     (mapcar #'first
                             (sqlite:execute-to-list db "PRAGMA compile_options"))
                     :test #'string=))
      (sqlite:disconnect db))))

(test foreign-library-loaded-at-file-load
  "The binding's foreign library is open once the library has loaded."
  (is (cffi:foreign-library-loaded-p 'sqlite-ffi::sqlite3-lib)))

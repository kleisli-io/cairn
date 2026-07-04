(in-package #:kli/cairn/tests)
(in-suite all)

;;; Many writers, each on an independent fd, append concurrently to one task log
;;; through the production %append-to-log. Every line runs well past SBCL's
;;; fd-stream buffer, so an unlocked writer would flush a single line as several
;;; write(2)s and interleave with a peer's; the LOCK_EX inside %append-to-log
;;; must serialize the appends so every line lands whole and parseable. A
;;; threaded, per-fd proxy for the same contention across processes.

(defparameter *big-line-writers* 8)
(defparameter *big-line-events* 50)
(defparameter *big-line-pad* 50000
  "Padding per event, well past SBCL's fd-stream buffer so one line flushes as
several write(2)s — the exact window the lock closes.")

(defun %big-event-line (writer i)
  "A canonical-JSON event line unique to (WRITER, I), padded past the stream
buffer."
  (let ((key (format nil "w~D-e~D" writer i)))
    (cairn::event->line
     (list :event-id key
           :event-key key
           :task-id "t"
           :type "observation"
           :ts (+ 3990100000 i)
           :data (list :pad (make-string *big-line-pad* :initial-element #\x))))))

(test concurrent-appends-never-tear-a-line
  "N writers hammering one log through %append-to-log yield exactly N*M whole,
JSON-valid lines carrying every distinct event_key exactly once."
  (let* ((dir (make-test-dir (temp-root) "flock"))
         (conns (loop for w below *big-line-writers*
                      collect (sqlite:connect
                               (namestring
                                (merge-pathnames (format nil "cairn-~D.db" w) dir)))))
         (go-gate (sb-thread:make-semaphore))
         (expected (make-hash-table :test 'equal)))
    (unwind-protect
         (progn
           (loop for w below *big-line-writers* do
             (dotimes (i *big-line-events*)
               (setf (gethash (format nil "w~D-e~D" w i) expected) t)))
           (let ((threads
                   (loop for w below *big-line-writers*
                         for db in conns
                         collect (sb-thread:make-thread
                                  (lambda (w db)
                                    (sb-thread:wait-on-semaphore go-gate)
                                    (dotimes (i *big-line-events*)
                                      (cairn::%append-to-log db "t" (%big-event-line w i))))
                                  :name (format nil "flock-writer-~D" w)
                                  :arguments (list w db)))))
             (sb-thread:signal-semaphore go-gate *big-line-writers*)
             (mapc #'sb-thread:join-thread threads))
           (let* ((logp (cairn::cairn-task-log-under dir "t"))
                  (lines (uiop:read-file-lines logp))
                  (seen (make-hash-table :test 'equal))
                  (bad-json 0))
             (dolist (line lines)
               (handler-case
                   (let ((key (getf (cairn::line->event-fields line) :event-key)))
                     (when key (setf (gethash key seen) t)))
                 (error () (incf bad-json))))
             (is (= (* *big-line-writers* *big-line-events*) (length lines))
                 "every append is one whole line, none split or merged")
             (is (zerop bad-json) "every line parses as JSON (no torn line)")
             (is (= (hash-table-count expected) (hash-table-count seen))
                 "every distinct event_key survives exactly once")
             (is (loop for k being the hash-keys of expected
                       always (gethash k seen))
                 "no expected event_key is missing")))
      (dolist (c conns) (ignore-errors (sqlite:disconnect c))))))

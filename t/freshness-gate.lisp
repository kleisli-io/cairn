(in-package #:kli/cairn/tests)
(in-suite all)

;;; The reconcile freshness gate: a per-log (mtime, size) stat decides whether a
;;; log must be re-read, and a shared epoch counter decides — in O(1) — whether a
;;; live store needs to sweep at all. An append grows the log and bumps the epoch;
;;; a store idle since its last sweep does no per-log work; a peer's write is
;;; visible on the next call.

(defun %fg-foreign-line (tag ts text)
  "A canonical-JSON observation line for task t, tagged unique by TAG."
  (cairn::event->line
   (list :event-id (concatenate 'string (make-string 25 :initial-element #\0) tag)
         :event-key (cairn::event-key "t" "observation" ts nil (list :text text))
         :task-id "t" :type "observation" :ts ts
         :session-id nil :prev-session-id nil
         :data (list :text text))))

(defun %fg-obs-count (db text)
  (sqlite:execute-single db
    "SELECT count(*) FROM observations WHERE text = ?" text))

(defun %fg-store-dir (db)
  (uiop:pathname-directory-pathname (cairn::%store-file db)))

(test freshness-gate-is-a-cheap-stat-not-a-content-hash
  "The per-log watermark is a short (mtime:size) stat: it tracks the byte size,
moves when the log grows, and moves on an mtime-only rewrite of identical bytes."
  (let* ((dir (make-test-dir (temp-root) "fg"))
         (path (namestring (merge-pathnames "cairn.db" dir)))
         (db (cairn:open-cairn-store path)))
    (unwind-protect
         (progn
           (cairn:record-event db "t" "task.create" '(:description "d") :raw-ts 3990400000)
           (let* ((logp (%store-log-path db "t"))
                  (wm1 (cairn::%file-watermark logp))
                  (size (with-open-file (s logp :element-type '(unsigned-byte 8))
                          (file-length s))))
             (is (< (length wm1) 40) "the watermark is a stat, not a 64-hex content hash")
             (is (= size (parse-integer (second (uiop:split-string wm1 :separator ":"))))
                 "the watermark's size field is the log's byte length")
             (cairn:record-event db "t" "observation" '(:text "grow") :raw-ts 3990400001)
             (let ((wm2 (cairn::%file-watermark logp)))
               (is (not (equal wm1 wm2)) "an append moves the watermark (size grew)")
               (let* ((st (sb-posix:stat logp))
                      (before-mtime (sb-posix:stat-mtime st)))
                 (sb-posix:utime logp (sb-posix:stat-atime st) (+ before-mtime 100))
                 (let ((wm3 (cairn::%file-watermark logp)))
                   (is (not (equal wm2 wm3))
                       "an mtime-only rewrite moves the watermark")
                   (is (equal (second (uiop:split-string wm2 :separator ":"))
                              (second (uiop:split-string wm3 :separator ":")))
                       "with the byte size unchanged"))))))
      (cairn:close-cairn-store db))))

(test ingest-logs-skips-an-unmoved-log-and-reads-a-moved-one
  "After a reconcile stamps the watermarks, an unchanged log is skipped; a log a
foreign writer grew is re-read and its new events folded in."
  (let* ((dir (make-test-dir (temp-root) "fg"))
         (path (namestring (merge-pathnames "cairn.db" dir)))
         (db (cairn:open-cairn-store path)))
    (unwind-protect
         (progn
           (cairn:record-event db "t" "task.create" '(:description "d") :raw-ts 3990410000)
           (cairn::reconcile-store db)
           (let ((unchanged (let ((cairn::*mirror-log-p* nil))
                              (cairn::ingest-logs db (%fg-store-dir db)))))
             (is (null unchanged) "an unchanged log ingests nothing"))
           (%append-raw-line (%store-log-path db "t")
                             (%fg-foreign-line "A" 3990410005 "foreign"))
           (let ((moved (let ((cairn::*mirror-log-p* nil))
                          (cairn::ingest-logs db (%fg-store-dir db)))))
             (is (not (null moved)) "the grown log is re-read and yields a new event"))
           (cairn:rebuild db)
           (is (= 1 (%fg-obs-count db "foreign")) "the foreign event is folded in"))
      (cairn:close-cairn-store db))))

(test unchanged-epoch-skips-the-sweep-a-bump-triggers-it
  "reconcile-if-stale trusts the epoch: a write that never bumped it stays
invisible, and only a bump makes the store sweep and pick the write up."
  (let* ((dir (make-test-dir (temp-root) "fg"))
         (path (namestring (merge-pathnames "cairn.db" dir)))
         (db (cairn:open-cairn-store path)))
    (unwind-protect
         (progn
           (cairn:record-event db "t" "task.create" '(:description "d") :raw-ts 3990420000)
           (cairn::reconcile-store db)
           ;; A raw append moves the log but not the epoch — the store cannot know.
           (%append-raw-line (%store-log-path db "t")
                             (%fg-foreign-line "B" 3990420005 "silent"))
           (cairn::reconcile-if-stale db)
           (is (zerop (%fg-obs-count db "silent"))
               "an unbumped write is not swept in")
           (cairn::%bump-epoch db)
           (cairn::reconcile-if-stale db)
           (is (= 1 (%fg-obs-count db "silent"))
               "the epoch bump makes the next call sweep it in"))
      (cairn:close-cairn-store db))))

(test reconcile-if-stale-ingests-a-peer-append-once
  "A peer append (log write plus epoch bump, no cache fold) is picked up on the
next call, and a second call over an unmoved epoch is a no-op that never dups it."
  (let* ((dir (make-test-dir (temp-root) "fg"))
         (path (namestring (merge-pathnames "cairn.db" dir)))
         (db (cairn:open-cairn-store path)))
    (unwind-protect
         (progn
           (cairn:record-event db "t" "task.create" '(:description "d") :raw-ts 3990430000)
           (cairn::reconcile-store db)
           (cairn::%append-to-log db "t" (%fg-foreign-line "C" 3990430005 "peer"))
           (cairn::reconcile-if-stale db)
           (is (= 1 (%fg-obs-count db "peer")) "the peer append is ingested")
           (cairn::reconcile-if-stale db)
           (is (= 1 (%fg-obs-count db "peer"))
               "a second call over an unmoved epoch dups nothing")
           (is (cairn:verify db) "the cache still folds its own log"))
      (cairn:close-cairn-store db))))

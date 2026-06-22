(in-package #:kli/cairn/tests)
(in-suite all)

;;; The per-task log is one canonical-JSON event per line. event->line and
;;; line->event-fields are inverse: the line carries every events column except
;;; the local seq, so a decoded line feeds straight back into record-event.

(defun %sample-event-fields ()
  (list :event-id "01J0000000000000000000000A"
        :event-key "abc123"
        :task-id "demo"
        :type "task.create"
        :ts 3990000100
        :session-id "S1"
        :prev-session-id "S0"
        :data '(:description "hello" :project-id "p")))

(test ndjson-round-trips-all-fields
  "decode(encode(fields)) preserves every carried field, including event_id and
prev_session_id, and the nested data payload."
  (let ((d (cairn::line->event-fields
            (cairn::event->line (%sample-event-fields)))))
    (is (string= "01J0000000000000000000000A" (getf d :event-id)))
    (is (string= "abc123" (getf d :event-key)))
    (is (string= "demo" (getf d :task-id)))
    (is (string= "task.create" (getf d :type)))
    (is (= 3990000100 (getf d :ts)))
    (is (string= "S1" (getf d :session-id)))
    (is (string= "S0" (getf d :prev-session-id)))
    (is (string= "hello" (getf (getf d :data) :description)))
    (is (string= "p" (getf (getf d :data) :project-id)))))

(test ndjson-encoding-is-byte-stable
  "Key order is canonical, so plist order does not change the bytes, and decode
then re-encode reproduces the line exactly."
  (let ((line (cairn::event->line (%sample-event-fields)))
        (shuffled (list :data '(:project-id "p" :description "hello")
                        :type "task.create" :ts 3990000100
                        :prev-session-id "S0" :session-id "S1"
                        :task-id "demo" :event-key "abc123"
                        :event-id "01J0000000000000000000000A")))
    (is (string= line (cairn::event->line shuffled))
        "plist order does not affect the encoding")
    (is (string= line (cairn::event->line (cairn::line->event-fields line)))
        "decode then re-encode is byte-identical")))

(test ndjson-line-is-single-json-object
  "A line is one JSON object with no embedded newline."
  (let ((line (cairn::event->line (%sample-event-fields))))
    (is (null (find #\Newline line)))
    (is (char= #\{ (char line 0)))
    (is (char= #\} (char line (1- (length line)))))))

(test ndjson-empty-data-is-empty-object
  "Empty payload serializes as {} and decodes back to NIL."
  (let ((line (cairn::event->line
               (list :event-id "E" :event-key "K" :task-id "t"
                     :type "observation" :ts 3990000000
                     :session-id nil :prev-session-id nil :data nil))))
    (is (search "\"data\":{}" line) "empty data is the empty object")
    (is (null (getf (cairn::line->event-fields line) :data))
        "the empty object decodes to a NIL payload")))

(test ndjson-null-session-round-trips
  "Absent session and prev-session encode as null and decode to NIL."
  (let ((d (cairn::line->event-fields
            (cairn::event->line
             (list :event-id "E" :event-key "K" :task-id "t"
                   :type "observation" :ts 3990000000
                   :session-id nil :prev-session-id nil :data '(:text "x"))))))
    (is (null (getf d :session-id)))
    (is (null (getf d :prev-session-id)))))

(test ndjson-escapes-unicode-and-control
  "Control characters and unicode in payload text survive the round-trip while
the line stays single-line."
  (let* ((text (format nil "tab~Cnl~Ccafé-λ" #\Tab #\Newline))
         (line (cairn::event->line
                (list :event-id "E" :event-key "K" :task-id "t"
                      :type "observation" :ts 3990000000
                      :session-id "S" :prev-session-id nil
                      :data (list :text text)))))
    (is (null (find #\Newline line)) "embedded newline is escaped, not literal")
    (is (string= text (getf (getf (cairn::line->event-fields line) :data) :text))
        "control and unicode text round-trips exactly")))

(test ndjson-carries-import-fields-only-when-present
  "legacy_id/source_seq/imported_at are omitted when absent and round-trip when
present."
  (let ((base (list :event-id "E" :event-key "K" :task-id "t"
                    :type "task.create" :ts 3990000000
                    :session-id nil :prev-session-id nil :data '(:description "d"))))
    (is (null (getf (cairn::line->event-fields (cairn::event->line base)) :legacy-id))
        "no import key when absent")
    (is (not (search "legacy_id" (cairn::event->line base)))
        "absent import fields are omitted from the line")
    (let ((d (cairn::line->event-fields
              (cairn::event->line
               (append base (list :legacy-id "leg-1" :source-seq 42
                                  :imported-at 3990000999))))))
      (is (string= "leg-1" (getf d :legacy-id)))
      (is (= 42 (getf d :source-seq)))
      (is (= 3990000999 (getf d :imported-at))))))

(test cairn-task-log-path-sits-beside-the-db
  "The per-task log resolves to tasks/<slug>/events.ndjson under the db parent."
  (let ((cairn:*cairn-db-path* #p"/tmp/cairn-demo/cairn.db"))
    (is (string= "/tmp/cairn-demo/tasks/demo/events.ndjson"
                 (uiop:native-namestring (cairn::cairn-task-log-path "demo"))))))

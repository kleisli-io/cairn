(in-package #:kli/cairn)

;;; The per-task log is canonical JSON, one event per line. event->line and
;;; line->event-fields are inverse: the line carries every events column except
;;; the local seq, so a decoded line feeds straight into record-event on any
;;; store and folds to the same projection. Keys are sorted for a byte-stable
;;; encoding; the data payload nests as an object ({} when empty); the import
;;; columns ride along only when present.

(defun %render-json-scalar (v)
  "V rendered as a JSON scalar: a quoted escaped string, an integer, or null."
  (with-output-to-string (out) (%canon-value v out)))

(defun event->line (fields)
  "Encode the event FIELDS plist as one canonical-JSON line."
  (flet ((f (k) (getf fields k)))
    (let ((pairs (list (cons "data" (canonical-json (f :data)))
                       (cons "event_id" (%render-json-scalar (f :event-id)))
                       (cons "event_key" (%render-json-scalar (f :event-key)))
                       (cons "prev_session_id" (%render-json-scalar (f :prev-session-id)))
                       (cons "session_id" (%render-json-scalar (f :session-id)))
                       (cons "task_id" (%render-json-scalar (f :task-id)))
                       (cons "ts" (%render-json-scalar (f :ts)))
                       (cons "type" (%render-json-scalar (f :type))))))
      (when (f :legacy-id)
        (push (cons "legacy_id" (%render-json-scalar (f :legacy-id))) pairs))
      (when (f :source-seq)
        (push (cons "source_seq" (%render-json-scalar (f :source-seq))) pairs))
      (when (f :imported-at)
        (push (cons "imported_at" (%render-json-scalar (f :imported-at))) pairs))
      (with-output-to-string (out)
        (write-char #\{ out)
        (loop for (pair . rest) on (sort pairs #'string< :key #'car) do
          (%json-write-string (car pair) out)
          (write-char #\: out)
          (write-string (cdr pair) out)
          (when rest (write-char #\, out)))
        (write-char #\} out)))))

(defun line->event-fields (line)
  "Decode one NDJSON LINE into an event-fields plist keyed for record-event:
:event-id :event-key :task-id :type :ts :session-id :prev-session-id :data, with
:legacy-id/:source-seq/:imported-at appended when the line carries them. JSON
null and absent fields decode to NIL."
  (let ((obj (com.inuoe.jzon:parse line)))
    (flet ((str (k) (let ((v (gethash k obj))) (and (stringp v) v)))
           (int (k) (let ((v (gethash k obj))) (and (integerp v) v))))
      (let ((fields (list :event-id (str "event_id")
                          :event-key (str "event_key")
                          :task-id (str "task_id")
                          :type (str "type")
                          :ts (int "ts")
                          :session-id (str "session_id")
                          :prev-session-id (str "prev_session_id")
                          :data (%json->lisp (gethash "data" obj))))
            (legacy (str "legacy_id"))
            (sseq (int "source_seq"))
            (iat (int "imported_at")))
        (when legacy (setf fields (append fields (list :legacy-id legacy))))
        (when sseq (setf fields (append fields (list :source-seq sseq))))
        (when iat (setf fields (append fields (list :imported-at iat))))
        fields))))

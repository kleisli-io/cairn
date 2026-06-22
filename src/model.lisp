(in-package #:kli/cairn)

(defparameter +cairn-statuses+
  '("open" "active" "completed" "abandoned" "blocked")
  "Closed status enum. The DDL CHECK mirrors this set.")

(defparameter +cairn-edge-types+
  '("phase-of" "depends-on" "related")
  "Closed lateral edge-type enum stored in the edges table.")

(defparameter +structural-edge-types+
  '("phase-of" "forked-from")
  "Raw edge-types that name the fibration: folded into parent_task_id, never
the edges table.")

(define-condition cairn-invalid-status (cairn-store-error)
  ((value :initarg :value :reader cairn-invalid-value))
  (:report (lambda (c s)
             (format s "~S is not a valid status; expected one of ~{~A~^, ~}."
                     (cairn-invalid-value c) +cairn-statuses+))))

(defun status-valid-p (status)
  (and (stringp status) (member status +cairn-statuses+ :test #'string=)))

(defun validate-status (status)
  "Return STATUS if it names the enum, else signal."
  (if (status-valid-p status) status (error 'cairn-invalid-status :value status)))

(defun structural-edge-type-p (raw)
  "True when RAW names a fibration edge folded into parent_task_id."
  (and (stringp raw) (member raw +structural-edge-types+ :test #'string=)))

(defun normalize-edge-type (raw)
  "Collapse a raw lateral edge-type onto the closed enum, preserving the
original in a tag. Returns (values enum-type tag); tag is NIL when RAW already
names the enum exactly."
  (let ((raw (and raw (string-downcase raw))))
    (cond
      ((null raw) (values "related" nil))
      ((string= raw "depends-on") (values "depends-on" nil))
      ((member raw '("blocks" "blocked-by") :test #'string=)
       (values "depends-on" raw))
      ((string= raw "related") (values "related" nil))
      (t (values "related" raw)))))

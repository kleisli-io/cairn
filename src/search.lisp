(in-package #:kli/cairn)

;;; Lexical search over the observation corpus. obs_fts is an external-content
;;; FTS5 projection of `observations`, kept in sync by the store triggers, so a
;;; query is a pure read: sanitize, MATCH, rank by BM25, render a snippet with
;;; task provenance. Identifiers and file:line spans survive the tokenizer
;;; whole; the sanitizer phrase-quotes them so they match literally instead of
;;; parsing as MATCH operators.

(defparameter +fts-query-specials+ '(#\" #\( #\) #\: #\- #\. #\/ #\^ #\* #\+)
  "Characters that carry meaning in an FTS5 MATCH expression; a token holding any
of them is phrase-quoted so it matches as a literal.")

(defun %fts-quote (term)
  "TERM wrapped as an FTS5 phrase, doubling any embedded quote."
  (with-output-to-string (out)
    (write-char #\" out)
    (loop for ch across term do
      (when (char= ch #\") (write-char #\" out))
      (write-char ch out))
    (write-char #\" out)))

(defun %fts-term (token)
  "One whitespace-delimited TOKEN as a safe FTS5 query atom, or NIL when empty. A
trailing * is kept as a prefix query; a token carrying special punctuation
becomes a quoted phrase so identifiers like tools.lisp:45-78 and depends-on
match literally."
  (let* ((prefix (and (> (length token) 1)
                      (char= (char token (1- (length token))) #\*)))
         (base (if prefix (subseq token 0 (1- (length token))) token)))
    (cond
      ((zerop (length base)) nil)
      ((some (lambda (ch) (member ch +fts-query-specials+)) base)
       (format nil "~A~:[~;*~]" (%fts-quote base) prefix))
      (prefix (format nil "~A*" base))
      (t base))))

(defun cairn-sanitize-fts-query (raw)
  "A freeform query turned into a safe FTS5 MATCH expression: tokens with special
punctuation are phrase-quoted, a trailing * stays a prefix query, and tokens join
with implicit AND. NIL when RAW yields no usable token."
  (let ((terms (loop for token in (uiop:split-string
                                   (string-trim '(#\Space #\Tab #\Newline #\Return) raw)
                                   :separator '(#\Space #\Tab #\Newline #\Return))
                     for term = (and (plusp (length token)) (%fts-term token))
                     when term collect term)))
    (when terms
      (format nil "~{~A~^ ~}" terms))))

(defun %ts-date (ts)
  "TS, a CL universal-time, as an ISO date in UTC."
  (multiple-value-bind (s m h day month year) (decode-universal-time ts 0)
    (declare (ignore s m h))
    (format nil "~4,'0D-~2,'0D-~2,'0D" year month day)))

(defun %format-search-results (rows query)
  (if (null rows)
      (format nil "No matching observations for ~S." query)
      (with-output-to-string (out)
        (loop for (slug ts snippet) in rows
              for i from 1 do
          (format out "~D. [~A]  (~A)~%   ~A~%" i slug (%ts-date ts) snippet)))))

(defun %obs-search (db match task limit)
  "BM25-ranked observation rows (slug ts snippet) matching the sanitized MATCH
string, optionally scoped to one task slug. snippet() and bm25() read through the
external-content table."
  (if task
      (sqlite:execute-to-list db
        "SELECT t.slug, o.ts, snippet(obs_fts, 0, '[', ']', '...', 12)
           FROM obs_fts
           JOIN observations o ON o.obs_id = obs_fts.rowid
           JOIN tasks t ON o.task_id = t.id
          WHERE obs_fts MATCH ? AND t.slug = ?
          ORDER BY rank LIMIT ?"
        match task limit)
      (sqlite:execute-to-list db
        "SELECT t.slug, o.ts, snippet(obs_fts, 0, '[', ']', '...', 12)
           FROM obs_fts
           JOIN observations o ON o.obs_id = obs_fts.rowid
           JOIN tasks t ON o.task_id = t.id
          WHERE obs_fts MATCH ?
          ORDER BY rank LIMIT ?"
        match limit)))

(defun run-task-search (tool parameters context &key call-id on-update)
  (declare (ignore tool call-id on-update))
  (let ((raw (tool-parameter parameters :query))
        (scope (let ((s (tool-parameter parameters :scope)))
                 (if (%blank-p s) "observations" (string-downcase s)))))
    (cond
      ((%blank-p raw) (%fail "query is required."))
      ;; tool.call indexing is designed but deferred until its corpus-scale
      ;; benchmark settles; the scope parameter keeps the surface forward-compatible.
      ((string= scope "tool-calls") (%text "Tool-call search is not enabled."))
      ((not (member scope '("observations" "all") :test #'string=))
       (%fail "scope must be observations, tool-calls, or all."))
      (t
       (let ((match (cairn-sanitize-fts-query raw)))
         (if (null match)
             (%text (format nil "No matching observations for ~S." raw))
             (let ((limit (%limit (tool-parameter parameters :limit) 10 50))
                   (task (%bare-slug (tool-parameter parameters :task_id))))
               (with-cairn-store-lock (context)
                 (handler-case
                     (%text (%format-search-results
                             (%obs-search (context-db context) match task limit)
                             raw))
                   (sqlite:sqlite-error ()
                     (%fail "Could not parse the search query ~S." raw)))))))))))

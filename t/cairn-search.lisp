(in-package #:kli/cairn/tests)
(in-suite all)

(test fts-query-sanitizer-quotes-specials-and-keeps-prefixes
  "Bare terms pass through; punctuation-bearing identifiers become phrases; a
trailing * stays a prefix; whitespace collapses; an empty query is NIL."
  (is (string= "nix" (cairn::cairn-sanitize-fts-query "nix")))
  (is (string= "\"depends-on\"" (cairn::cairn-sanitize-fts-query "depends-on")))
  (is (string= "\"tools.lisp:45-78\"" (cairn::cairn-sanitize-fts-query "tools.lisp:45-78")))
  (is (string= "weav*" (cairn::cairn-sanitize-fts-query "weav*")))
  (is (string= "nix \"depends-on\"" (cairn::cairn-sanitize-fts-query "  nix   depends-on  ")))
  (is (null (cairn::cairn-sanitize-fts-query "   "))))

(test task-search-matches-identifiers-paths-and-keywords
  "nix and lisp are not stopwords; underscored/hyphenated identifiers and
file:line spans match whole; a trailing * is a prefix query."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "the search corpus seed task") context)
    (ext:invoke-tool protocol :observe
                     (list :text "the nix build uses the weaver pattern in tools.lisp:45-78 to assemble outputs")
                     context)
    (ext:invoke-tool protocol :observe
                     (list :text "the lisp reader keeps depends-on and task_fork tokens whole")
                     context)
    (let ((slug (cairn:current-task-id context)))
      (flet ((hits (q)
               (let ((text (tool-text (ext:invoke-tool protocol :task_search
                                                       (list :query q) context))))
                 (and (search slug text) (not (search "No matching" text))))))
        (is (hits "nix") "nix is not stopword-stripped")
        (is (hits "lisp") "lisp is not stopword-stripped")
        (is (hits "task_fork") "underscored identifiers match whole")
        (is (hits "depends-on") "hyphenated identifiers match as a phrase")
        (is (hits "tools.lisp:45-78") "file:line spans match as a phrase")
        (is (hits "weav*") "prefix queries match")))))

(test task-search-highlights-the-match-in-the-snippet
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "the snippet highlight task") context)
    (ext:invoke-tool protocol :observe
                     (list :text "the canary token appears in this observation") context)
    (let ((text (tool-text (ext:invoke-tool protocol :task_search
                                            (list :query "canary") context))))
      (is (search "[canary]" text)
          "snippet() brackets the matched term"))))

(test task-search-ranks-shorter-documents-higher
  "BM25 length normalization: with equal term frequency the shorter observation
outranks the longer one."
  (with-cairn-protocol (context protocol)
    (let ((short (created-slug (ext:invoke-tool protocol :task_create
                                                (list :name "the short needle document task") context)))
          (long (created-slug (ext:invoke-tool protocol :task_create
                                               (list :name "the long padded haystack document task") context))))
      (ext:invoke-tool protocol :observe (list :text "needle" :task_id short) context)
      (ext:invoke-tool protocol :observe
                       (list :text "needle buried in a very long haystack of many other unrelated padding words here"
                             :task_id long)
                       context)
      (let ((text (tool-text (ext:invoke-tool protocol :task_search
                                              (list :query "needle") context))))
        (is (search short text) "the short document matches")
        (is (search long text) "the long document matches")
        (is (< (search short text) (search long text))
            "the shorter document ranks first")))))

(test task-search-scopes-to-a-single-task
  (with-cairn-protocol (context protocol)
    (let ((a (created-slug (ext:invoke-tool protocol :task_create
                                            (list :name "the first scoped corpus task") context)))
          (b (created-slug (ext:invoke-tool protocol :task_create
                                            (list :name "the second scoped corpus task") context))))
      (ext:invoke-tool protocol :observe (list :text "the shared apple keyword" :task_id a) context)
      (ext:invoke-tool protocol :observe (list :text "the shared apple keyword" :task_id b) context)
      (let ((text (tool-text (ext:invoke-tool protocol :task_search
                                              (list :query "apple" :task_id a) context))))
        (is (search a text) "the scoped task is present")
        (is (not (search b text)) "the other task is excluded")))))

(test task-search-survives-a-fts-rebuild
  "The FTS index is a derived projection: rebuilding it from the observations
table reproduces the identical ranked result set."
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "the fts rebuild corpus task") context)
    (ext:invoke-tool protocol :observe
                     (list :text "the durable observation about extractor drift") context)
    (flet ((q () (tool-text (ext:invoke-tool protocol :task_search
                                             (list :query "extractor") context))))
      (let ((before (q)))
        (is (search "extractor" before) "the observation is found before rebuild")
        (cairn:rebuild-fts (task-db protocol))
        (is (string= before (q))
            "the rebuilt index yields the same result text")))))

(test task-search-requires-a-query
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "the blank query guard task") context)
    (is (ext:tool-result-error-p
         (ext:invoke-tool protocol :task_search (list :query "") context)))))

(test task-search-reports-no-matches-cleanly
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "the empty result corpus task") context)
    (ext:invoke-tool protocol :observe (list :text "some ordinary note") context)
    (let ((text (tool-text (ext:invoke-tool protocol :task_search
                                            (list :query "zzzznomatchxyzzy") context))))
      (is (search "No matching" text)))))

(test task-search-tool-call-scope-is-deferred-and-bad-scope-errors
  (with-cairn-protocol (context protocol)
    (ext:invoke-tool protocol :task_create
                     (list :name "the deferred scope task") context)
    (let ((result (ext:invoke-tool protocol :task_search
                                   (list :query "anything" :scope "tool-calls") context)))
      (is (not (ext:tool-result-error-p result)))
      (is (search "not enabled" (tool-text result))))
    (is (ext:tool-result-error-p
         (ext:invoke-tool protocol :task_search
                          (list :query "anything" :scope "bogus") context)))))

(defpackage #:kli/cairn/tests
  (:use #:cl #:fiveam)
  (:local-nicknames
   (#:kli #:kli)
   (#:ext #:kli/ext)
   (#:obj #:kli/object)
   (#:event #:kli/event)
   (#:commands #:kli/interaction/commands)
   (#:config #:kli/config)
   (#:session #:kli/agent/session)
   (#:log #:kli/session/log)
   (#:cairn #:kli/cairn))
  (:export #:all))

(in-package #:kli/cairn/tests)

(def-suite all)
(in-suite all)

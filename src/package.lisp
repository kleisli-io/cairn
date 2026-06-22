(defpackage #:kli/cairn
  (:use #:cl)
  (:import-from #:kli
                #:live-object
                #:object-id
                #:context-registry
                #:find-live-object
                #:active-protocol)
  (:import-from #:kli/ext
                #:defextension
                #:protocol-storage
                #:protocol-storage-table
                #:require-capability-provider
                #:find-capability-provider
                #:provider-call
                #:invoke-tool
                #:tool-parameter
                #:make-tool-result
                #:make-tool-text-content
                #:contribution-extension
                #:contribution-state
                #:tool-result-content
                #:tool-result-details
                #:tool-result-error-p)
  (:import-from #:kli/agent/session
                #:session-mode-bindings
                #:mode-binding-session-binding
                #:session-binding-session-id
                #:session-context-transform-policy
                #:recode-context-transform-policy
                #:session-compaction-policy
                #:recode-compaction-policy
                #:follow-up-agent-session
                #:agent-session-context
                #:agent-session-busy-p)
  (:import-from #:kli/session/log
                #:make-user-message
                #:message-timestamp)
  (:import-from #:kli/context/lens
                #:stage-context-patch
                #:commit-context-patches
                #:make-append-message-patch)
  (:import-from #:kli/interaction/commands
                #:make-command
                #:make-command-result
                #:make-command-text-content
                #:reply
                #:rest-arg)
  (:import-from #:kli/config
                #:directory-ancestors
                #:*project-start-directory*
                #:expand-config-path
                #:find-config-service
                #:config-service-settings
                #:settings-value
                #:register-extension-resource-roots)
  (:export
   #:cairn-store
   #:make-cairn-store
   #:find-cairn-store
   #:cairn-store-path
   #:open-cairn-store
   #:close-cairn-store
   #:cairn-store-error
   #:cairn-store-missing-fts5
   #:cairn-data-home
   #:resolve-cairn-db-path
   #:resolve-cairn-db-location
   #:*cairn-db-path*
   #:+cairn-db-key+
   #:+current-task-key+
   #:+cairn-project-key+
   #:current-task-id
   #:current-project-id
   ;; project identity + locality
   #:project-cairn-dir
   #:project-repo-root
   #:resolve-project
   #:derive-project-id
   #:ensure-project-row
   #:ensure-db-gitignore
   #:ensure-log-gitattributes
   #:cairn-project
   #:cp-project-id
   #:cp-root-path
   #:cp-display-name
   #:cp-source
   #:+scratch-project-id+
   #:*cairn-extension-manifest*
   ;; schema + write boundary
   #:apply-schema
   #:record-event
   #:apply-event-to-projection
   #:rebuild
   #:rebuild-fts
   #:verify
   #:make-ulid
   #:encode-crockford
   #:event-key
   #:canonical-ts
   #:canonical-json
   #:split-depot
   #:cairn-event
   #:current-session-id
   ;; model
   #:+cairn-statuses+
   #:+cairn-edge-types+
   #:+structural-edge-types+
   #:status-valid-p
   #:validate-status
   #:structural-edge-type-p
   #:normalize-edge-type
   #:cairn-invalid-status
   #:cairn-invalid-value))

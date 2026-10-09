;;; module/playnet/gateway/oobi-host.scm — moved to (playnet identity oobi-host) (module/playnet/identity/oobi-host.scm).
;;; A re-export shim: importers name the new module; the shim goes once
;;; every importer in every tree does (identity centralization, step 2).

(define-module (playnet gateway oobi-host)
  #:use-module (playnet identity oobi-host)
  #:re-export (^oobi-host oobi-host-spawn-from-dir oobi-entry-path read-oobi-entry-from-dir read-oobi-entries-from-dir oobi-entry-last-event oobi-current-key-from-dir oobi-write-entry-to-dir!))

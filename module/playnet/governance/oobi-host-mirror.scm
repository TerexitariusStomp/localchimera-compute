;;; module/playnet/governance/oobi-host-mirror.scm — moved to (playnet identity oobi-host-mirror) (module/playnet/identity/oobi-host-mirror.scm).
;;; A re-export shim: importers name the new module; the shim goes once
;;; every importer in every tree does (identity centralization, step 4).

(define-module (playnet governance oobi-host-mirror)
  #:use-module (playnet identity oobi-host-mirror)
  #:re-export (^oobi-host-mirror spawn-oobi-host-mirror))

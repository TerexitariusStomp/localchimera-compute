;;; module/playnet/gateway/signup-agent.scm — moved to (playnet identity seat) (module/playnet/identity/seat.scm).
;;; A re-export shim: importers name the new module; the shim goes once
;;; every importer in every tree does (identity centralization, step 2).

(define-module (playnet gateway signup-agent)
  #:use-module (playnet identity seat)
  #:re-export (^signup-agent signup-agent-env verify-self-signed-icp verify-rotation-event verify-rotation-run verify-carried-kel normalize-vecs aid-tag))

;;; module/playnet/gateway/forget.scm — moved to (playnet identity forget) (module/playnet/identity/forget.scm).
;;; A re-export shim: importers name the new module; the shim goes once
;;; every importer in every tree does (identity centralization, step 1).

(define-module (playnet gateway forget)
  #:use-module (playnet identity forget)
  #:re-export (forget-member! forgotten? forgotten-gated unmark-forgotten!))

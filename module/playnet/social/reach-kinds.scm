;;; module/playnet/social/reach-kinds.scm — moved to (playnet identity reach-kinds) (module/playnet/identity/reach-kinds.scm).
;;; A re-export shim: importers name the new module; the shim goes once
;;; every importer in every tree does (identity centralization, step 3).

(define-module (playnet social reach-kinds)
  #:use-module (playnet identity reach-kinds)
  #:re-export (%reach-kinds reach-id reach-label reach-example reach-link reach-commune? reach-kind commune-reach-kinds reach-value-fault %reach-value-max))

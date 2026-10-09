;;; module/playnet/gateway/contact-points.scm — moved to (playnet identity contact-points) (module/playnet/identity/contact-points.scm).
;;; A re-export shim: importers name the new module; the shim goes once
;;; every importer in every tree does (identity centralization, step 3).

(define-module (playnet gateway contact-points)
  #:use-module (playnet identity contact-points)
  #:re-export (contact-point-wire->cred contact-point-verdict make-contact-point-desk %confirm-ttl %confirm-attempts %confirm-budget %confirm-window))

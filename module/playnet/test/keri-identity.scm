;;; module/playnet/test/keri-identity.scm — moved to (playnet identity fixture) (module/playnet/identity/fixture.scm).
;;; A re-export shim: importers name the new module; the shim goes once
;;; every importer in every tree does (identity centralization, step 1).

(define-module (playnet test keri-identity)
  #:use-module (playnet identity fixture)
  #:re-export (keypair->aid-prefix test-identity lobby-fixture))

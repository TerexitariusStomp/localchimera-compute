;;; module/playnet/gateway/cards.scm — moved to (playnet identity cards) (module/playnet/identity/cards.scm).
;;; A re-export shim: importers name the new module; the shim goes once
;;; every importer in every tree does (identity centralization, step 3).

(define-module (playnet gateway cards)
  #:use-module (playnet identity cards)
  #:re-export (%card-schema %card-max-sealed person-aid? card-said card-wire->card card-verdict card-at card-put! card-get card-drop! cards-forget!))

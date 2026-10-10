;;; sheds.scm — the bioregions the tree ships, registered.
;;;
;;; Each regional world registers its bioregion on import (register-bioregion!,
;;; bioregions.scm), so any live scope placed contained-in a shed inherits its
;;; climate futures and its limits by the containment walk. Registration is inert
;;; until a scope sits in a shed. This module is the one list of the sheds a
;;; scope's solve knows: a new world joins the solve by joining it.

(define-module (playnet knowledge worlds sheds)
  #:use-module (playnet knowledge worlds doon-shed)
  #:use-module (playnet knowledge worlds cascadia)
  #:use-module (playnet knowledge worlds berlin)
  #:use-module (playnet knowledge worlds bay-area))

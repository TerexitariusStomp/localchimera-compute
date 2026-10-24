;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; sheds.scm — the bioregions the tree ships, registered.
;;;
;;; Each regional world registers its bioregion on import (register-bioregion!,
;;; bioregions.scm), so any live scope placed contained-in a shed inherits its
;;; climate futures and its limits by the containment walk. Registration is inert
;;; until a scope sits in a shed. This module is the one list of the sheds a
;;; scope's solve knows: a new world joins the solve by joining it.

(define-module (localchimera knowledge worlds sheds)
  #:use-module (localchimera knowledge worlds doon-shed)
  #:use-module (localchimera knowledge worlds cascadia)
  #:use-module (localchimera knowledge worlds berlin)
  #:use-module (localchimera knowledge worlds bay-area))

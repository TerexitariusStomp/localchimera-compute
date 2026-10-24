;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/utils/boot-cell.scm — boot-time global cells
;;;
;;; For values the gateway sets once at boot and actors read from any
;;; vat: a plain shared cell with parameter-call syntax — (cell) reads,
;;; (cell v) sets.
;;;
;;; Why not make-parameter: parameters are per-dynamic-state, and a
;;; VAT inherits the dynamic state of its spawn moment. A vat spawned
;;; BEFORE the boot code sets the parameter never sees the value —
;;; reads inside its actor methods silently return #f. That is a
;;; spawn-order landmine (proven empirically; see
;;; tests/keys/test-pending-grants-fiber-inheritance.scm).
;;; A boot cell is one mutable location shared by every thread, so
;;; boot order cannot matter. The cost: no parameterize — tests
;;; set and restore explicitly.

(define-module (localchimera utils boot-cell)
  #:export (make-boot-cell))

(define* (make-boot-cell #:optional (value #f))
  (case-lambda
    (() value)
    ((new) (set! value new) new)))

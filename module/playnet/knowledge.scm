;;; knowledge.scm — Relational query utilities for playnet
;;;
;;; in-list-o for querying plain fact lists, transitive-o for
;;; depth-bounded transitive closure. transitive-o delegates to
;;; transitive-closure-o from (playnet kanren).
;;;
;;; Hoot/WASM compatible.

(define-module (playnet knowledge)
  #:use-module (playnet kanren)
  #:export (;; List membership (concrete Scheme lists)
            in-list-o
            ;; Transitive closure with proof traces
            transitive-o
            ;; Proof utilities
            proof-steps proof-length))


;;; ── in-list-o ─────────────────────────────────────────────────────────────────

(define (in-list-o x lst)
  "x is a member of concrete Scheme list LST.
   Produces conde branches — one per element."
  (if (null? lst)
      fail
      (conde
       ((== x (car lst)))
       ((in-list-o x (cdr lst))))))


;;; ── Transitive closure (delegates to kanren combinator) ──────────────────────

(define *default-max-depth* 10)

(define* (transitive-o edge-o start end trace #:optional (depth *default-max-depth*))
  "Depth-bounded transitive closure over any edge relation.
   Delegates to transitive-closure-o from (playnet kanren)."
  (transitive-closure-o edge-o start end trace depth))


;;; ── Proof trace utilities ─────────────────────────────────────────────────────

(define (proof-steps trace) trace)
(define (proof-length trace)
  (if (null? trace) 0 (- (length trace) 1)))

;;; knowledge.scm — Relational query utilities for playnet
;;;
;;; Generic transitive closure with proof traces, plus in-list-o for
;;; querying plain fact lists. No hyperarc dependency — facts are plain
;;; tagged tuples queried via unification.
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


;;; ── Transitive closure with proof traces ──────────────────────────────────────
;;; Generic: takes an edge relation as parameter, not tied to any data structure.
;;; EDGE-O: a goal constructor (lambda (from to) goal) that relates two values.

(define *default-max-depth* 10)

(define* (transitive-o edge-o start end trace #:optional (depth *default-max-depth*))
  "Depth-bounded transitive closure over any edge relation.
   EDGE-O: (lambda (from to) goal) — relates two connected values.
   TRACE: list of values visited (start mid1 ... end).
   Returns all paths from START to END up to DEPTH edges."
  (transitive-step edge-o start end trace depth))

(define (transitive-step edge-o start end trace depth)
  (if (= depth 0)
      fail
      (conde
       ;; Base: direct edge
       ((edge-o start end)
        (== trace (list start end)))
       ;; Step: one edge then recurse
       ((fresh (mid rest-trace)
          (edge-o start mid)
          (transitive-step edge-o mid end rest-trace (- depth 1))
          (== trace (cons start rest-trace)))))))


;;; ── Proof trace utilities ─────────────────────────────────────────────────────

(define (proof-steps trace) trace)
(define (proof-length trace)
  (if (null? trace) 0 (- (length trace) 1)))

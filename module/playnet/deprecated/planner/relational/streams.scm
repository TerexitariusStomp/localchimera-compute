;;; streams.scm — Lazy stream utilities
;;;
;;; A lazy stream is one of:
;;;   '()              — empty
;;;   (cons head tail) — head with materialized tail
;;;   (lambda () ...)  — thunk producing the next stream cell
;;;
;;; This convention is used throughout the relational federation
;;; substrate. miniKanren produces these naturally; the federation
;;; threads them through interleaving and search-step expansion.
;;;
;;; Operations:
;;;   stream-map-lazy  — map a function over a stream lazily
;;;   stream-take-1    — pull one element, returning (head . tail) or #f
;;;   stream-take-best — force the entire stream, return its last element
;;;   pull-from-all    — pull one element from each child stream

(define-module (playnet deprecated planner relational streams)
  #:export (stream-map-lazy stream-take-1 stream-take-best pull-one-each))

(use-modules (srfi srfi-1))


(define (stream-map-lazy f s)
  "Apply F to each element of stream S lazily. Forces only as far as
   the consumer pulls."
  (cond
    ((null? s) '())
    ((procedure? s) (lambda () (stream-map-lazy f (s))))
    (else (cons (f (car s)) (stream-map-lazy f (cdr s))))))

(define (stream-take-1 s)
  "Pull one element from stream S. Returns (head . tail) or #f if empty.
   Drives any thunks until a head is materialized or the stream ends."
  (cond
    ((null? s) #f)
    ((procedure? s) (stream-take-1 (s)))
    (else (cons (car s) (cdr s)))))

(define (stream-take-best s)
  "Force the entire stream, return the last (most-improved) element.
   Used by federation searches that produce monotonically-improving
   federation-results — the last element is the best one available."
  (let loop ((s s) (last #f))
    (cond
      ((null? s) last)
      ((procedure? s) (loop (s) last))
      (else (loop (cdr s) (car s))))))

(define (pull-one-each child-streams)
  "Pull one element from each child stream. CHILD-STREAMS is an alist
   of (child-id . stream). Returns a list of (child-id . pulled) pairs,
   where PULLED is (head . tail) for non-empty streams or #f for empty.
   The caller is responsible for wrapping these into whatever shape
   they need."
  (map (lambda (cs)
         (cons (car cs) (stream-take-1 (cdr cs))))
       child-streams))

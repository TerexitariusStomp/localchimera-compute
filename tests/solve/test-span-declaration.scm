;;; test-span-declaration.scm — span is governed, location is fact.
;;;
;;; docs/planning/federation/patchwork-scopes-containment.md §2.3: where a means sits is
;;; the world's answer; how far its service pools is an allocation decision.
;;; *span-of* carries the decision (resource-id → place) and the pool-builder
;;; reads it in place of the holding place — in EITHER direction:
;;;
;;;   narrower  the lathe sits at the town hall but serves only workshop a
;;;   wider     the lathe sits in workshop a but is declared to serve the town
;;;   absent    the holding place, byte-identical to the behaviour before
;;;
;;; The resource's own location is never touched: same records, different
;;; declaration, different pool — which is what "a declaration that references
;;; places rather than being places" means. containment-place-test pins the
;;; pool structure, pool-steering-test its dynamic; this pins WHO DECIDES ITS
;;; EXTENT.
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-span-declaration.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve ingest) (playnet solve world)
             (playnet solve compile)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
(define (near? a b) (< (abs (- a b)) 1e-6))

;; town ⊃ workshops a, b — the spatial tree; a and b are the planning places.
(define town (place* "town" #:name "Town" #:lat #f #:lon #f))
(define pa   (place* "a" #:name "Workshop A" #:lat #f #:lon #f #:parent "town"))
(define pb   (place* "b" #:name "Workshop B" #:lat #f #:lon #f #:parent "town"))

(define (res id spec qty unit at) (er id spec #f #:place at #:qty qty #:unit unit))

(define (world! lathe span)
  (declare-world! #:places '("a" "b") #:spans '((0 "2026-03-03" "2026-03-03"))
                  #:templates
                    (list (list "p-turn" '(("part" . 1.0))
                                (list (cons (svc-good "lathe") 1.0)) 0.0 '() '() '() '() '()))
                  #:spatial-things (list town pa pb))
  (when span (hash-set! *span-of* "lathe-1" span))
  (ingest-stock! (list lathe)))

(define (pool-cells)                          ; the cp| pool's cells, or #f
  (and=> (find (lambda (p) (string-prefix? "cp|lathe-1" (car p))) *container-pools*) caddr))
(define (cap-at p)
  (hash-ref *cap* (lg (svc-good "lathe") (cell p 0)) 0.0))

(format #t "~%── the same lathe, three declarations ──~%~%")

;; 1. held at the town, no declaration → the pool spans a and b (as always)
(world! (res "lathe-1" "lathe" 40.0 "hours/day" "town") #f)
(format #t "    held at town, span absent   → pool ~a~%" (pool-cells))
(check "absent declaration: the pool spans the holding place's cells"
       (equal? (pool-cells) (list (cell "a" 0) (cell "b" 0))))

;; 2. held at the town, span declared "a" → the pool NARROWS to a; b gets nothing
(world! (res "lathe-1" "lathe" 40.0 "hours/day" "town") "a")
(format #t "    held at town, span = a      → pool ~a, cap a=~a b=~a~%"
        (pool-cells) (cap-at "a") (cap-at "b"))
(check "narrower span: no multi-cell pool is built"     (not (pool-cells)))
(check "…the capacity stands at the declared place"     (near? 40.0 (cap-at "a")))
(check "…and none leaks to the sibling"                 (near? 0.0 (cap-at "b")))

;; 3. held at workshop a, span declared "town" → the pool WIDENS to a and b
(world! (res "lathe-1" "lathe" 40.0 "hours/day" "a") "town")
(format #t "    held at a,    span = town   → pool ~a~%" (pool-cells))
(check "wider span: the pool spans the declared container's cells"
       (equal? (pool-cells) (list (cell "a" 0) (cell "b" 0))))

;; 4. and the location was never touched: same record every time
(check "the resource's own location is untouched by any of it"
       (equal? "town" (economic-resource-current-location
                       (res "lathe-1" "lathe" 40.0 "hours/day" "town"))))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — span is a declaration about a place,~%  not a place: the pool follows the declaration, the lathe~%  stays exactly where it is.~%" *pass*)
    (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)))
(format #t "════════════════════════════════════════════~%")
(exit (if (> *fail* 0) 1 0))

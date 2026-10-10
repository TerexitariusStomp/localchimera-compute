;;; test-containment-place.scm — a thing inside a thing is somewhere.
;;;
;;; `contained-in` names a container; the container names where it is. So the place
;;; of a contained holding is a WALK up that chain to the first ancestor that states
;;; a location: seats are in a train, the train is at a station, the seats are at
;;; that station.
;;;
;;; Reading the container's ID as the place instead puts the seats in a cell called
;;; "train" — a cell no arc reaches and no other holding shares — so a capacity held
;;; that way is spatially disconnected from the plan that needs it. The walk is what
;;; makes containment mean location rather than merely mean parentage.
;;;
;;; The second half is the SHARED POOL: a means that reaches several cells is
;;; bounded in TOTAL across them, not that much capacity repeated at each. That is
;;; one bar over a set of located draws, and it is the same construction whether the
;;; set spans places (the seats of a line, spendable at any of its stations) or
;;; periods (a budget, spendable whenever inside its window).
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-containment-place.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet knowledge dsl shorthand))
(use-modules (playnet solve engine)
             (playnet solve compile)
             (playnet vf schemas))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
(define (near? a b) (< (abs (- a b)) 0.001))

;; id · spec · qty · unit · at (a place, or #f) · inside (a container id, or #f)
(define (res id spec qty unit at inside)
  (er id spec #f #:place at #:qty qty #:unit unit #:contained-in inside))

(format #t "~%── 1. the place of a contained thing ──~%~%")

;; seats ⊂ train @ alexanderplatz
(define seats  (res "seats"  "seat"  200.0 "hours/day" #f "train-u2"))
(define train  (res "train-u2" "train" 1.0 %count-unit "alexanderplatz" #f))
(define fleet  (list seats train))
(define resolve (resource-resolver fleet))

(check "a holding that states its own location is there"
       (equal? "alexanderplatz" (resource-place train resolve)))
(check "seats in a train are where the TRAIN is, not in a cell called \"train-u2\""
       (equal? "alexanderplatz" (resource-place seats resolve)))

;; three deep: a crate in a container in a ship
(define ship  (res "ship"  "ship"  1.0 %count-unit "hamburg" #f))
(define box   (res "box"   "box"   1.0 %count-unit #f "ship"))
(define grain (res "grain" "grain" 50.0 "kg"  #f "box"))
(define cargo (list ship box grain))
(check "the walk goes as deep as the nesting does"
       (equal? "hamburg" (resource-place grain (resource-resolver cargo))))

;; A container nobody handed us is still a place — the reading a solve given no
;; resource list can honestly make, and what keeps an ECOLOGICAL container (a
;; SpatialThing, never an EconomicResource) working as the place of its contents.
(define tree (res "tree" "timber" 10.0 "m3" #f "amazon"))
(check "an unresolvable container remains the place of what it holds"
       (equal? "amazon" (resource-place tree (resource-resolver (list tree)))))
(check "…and with no resolver at all, likewise"
       (equal? "amazon" (resource-place tree)))

;; A cycle terminates rather than spinning: two crates each inside the other.
(define c1 (res "c1" "crate" 1.0 %count-unit #f "c2"))
(define c2 (res "c2" "crate" 1.0 %count-unit #f "c1"))
(check "a containment cycle stops instead of looping"
       (string? (resource-place c1 (resource-resolver (list c1 c2)))))

(format #t "~%── 2. the capacity lands in the container's place ──~%~%")

(define (tpl spec)
  (list (string-append "p-" spec) '(("thing" . 1.0))
        (list (cons (string-append "Svc|" spec) 1.0)) 0.0 '() '() '() '() '()))

(declare-world! #:spans '((0 "2026-03-03" "2026-03-03"))
                #:templates (list (tpl "seat")))
(ingest-stock! fleet)
(check "the seats' service is capped at the station, not at the train"
       (and (near? 200.0 (hash-ref *cap* (lg (svc-good "seat") (cell "alexanderplatz" 0)) 0.0))
            (= 0.0 (hash-ref *cap* (lg (svc-good "seat") (cell "train-u2" 0)) 0.0))))

(format #t "~%── 3. a pool spanning cells is bounded across them ──~%~%")

;; One supplier reaching two cells. The bar is over its entries, so the two draws
;; share ONE budget: this is the construction a line's seats and a bankable budget
;; both use, and the property that makes it a pool rather than a copy.
(define (bundle-for cells)
  (declare-world! #:places '("a" "b") #:spans '((0 "2026-03-03" "2026-03-03"))
                  #:templates (list (tpl "m"))
                  #:resource-suppliers (list (list "pool" '("m") cells 30.0 #t)))
  (build-columns)
  (find (lambda (b) (equal? "pool" (car b))) *supplier-bundles*))

(let ((one (bundle-for (cell "a" 0)))
      (two (bundle-for (list (cell "a" 0) (cell "b" 0)))))
  (format #t "    one cell: ~a draw(s) on a budget of ~a~%" (length (cadddr one)) (cadr one))
  (format #t "    two cells: ~a draw(s) on a budget of ~a~%" (length (cadddr two)) (cadr two))
  (check "a single-cell supplier is one draw on its budget"
         (and one (= 1 (length (cadddr one))) (near? 30.0 (cadr one))))
  (check "a two-cell pool is two draws on the SAME budget"
         (and two (= 2 (length (cadddr two))) (near? 30.0 (cadr two))))
  (check "…and the draws sit in the two different cells"
         (equal? (list (cell "a" 0) (cell "b" 0))
                 (sort (map cadr (cadddr two)) string<?))))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — a contained thing is where its container is,~%  and a pool that reaches several cells is one budget across them.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")

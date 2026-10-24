;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-confirmed-move.scm — a confirmed relocation carries its stock, exactly.
;;;
;;; A plan carries stock between places as a `pickup` at the origin and a `dropoff` at the
;;; destination, two rows of one run (a Process of its own). Enacting the pair decrements the
;;; origin resource and increments the lot the cargo lands in, so the spec's total on hand is
;;; conserved and the stock stands where the plan carried it. This pins that through the real
;;; enaction path (enact-rows, as the `enact` door calls it), both for a single pair and for a
;;; whole planned carry.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/scope/test-confirmed-move.scm

(use-modules ((localchimera vf formulas flows) #:select (row-figure))
             (localchimera test scope)
             (localchimera test harness)
             (localchimera test books)
             (localchimera observation observer) (localchimera vf schemas) (srfi srfi-1)
             (localchimera scope live)
             (goblins) (goblins vat)
             (srfi srfi-1))

(define (seed obs)
  ($ obs 'seed-resource
     (make-economic-resource #:id "crate-1" #:name "crate-1" #:conforms-to "water"
                             #:accounting-quantity (make-measure 100.0 "L") #:onhand-quantity (make-measure 100.0 "L")
                             #:current-location "A" #:primary-accountable "commune")))

(define (world proc)
  (with-vat (spawn-vat #:name "confirmed-move")
    (let* ((obs (spawn ^observer (empty-observer-state) '()))
           (as  (spawn ^mock `((all-agents . ,(lambda () '())))))
           (sts (spawn ^mock `((all-locations
                                . ,(lambda ()
                                     (list (make-spatial-thing #:id "A" #:name "A" #:lat 0.0
                                                               #:long 0.0)
                                           (make-spatial-thing #:id "B" #:name "B" #:lat 0.0
                                                               #:long 0.05)))))))
           (rs  (spawn ^mock `((all-recipes . ,(lambda () '()))
                               (get-process-chain . ,(lambda (r) '()))
                               (flows-for-process . ,(lambda (pid) (cons '() '()))))))
           (scope (mock-scope-root #:observer obs #:agent-store as
                                   #:spatial-thing-store sts #:recipe-store rs)))
      (seed obs)
      (proc obs scope))))

;; ── a single pair, as the doors hand it to enact-rows ──────────────────────────
(define (pair-rows id q)
  (list `((id . ,(string-append id ".pu")) (action . pickup) (conforms-to . "water") (quantity . ,q)
          (at-location . "A") (input-of . ,id) (output-of . #f) (note . #f))
        `((id . ,(string-append id ".do")) (action . dropoff) (conforms-to . "water") (quantity . ,q)
          (at-location . "B") (input-of . #f) (output-of . ,id) (note . #f))))
(define (totals obs) (list (spec-total obs "water") (spec-total obs "water" #:place "A") (spec-total obs "water" #:place "B")))
(define single
  (world (lambda (obs scope)
           (enact-rows scope (pair-rows "run1" 20.0))
           (totals obs))))

(display "\n── a confirmed carry: the 20 litres arrive ──\n")
(check "the spec's total on hand is conserved"        (list-ref single 0) 100.0)
(check "the origin holds what was left"               (list-ref single 1) 80.0)
(check "the destination holds what was carried"       (list-ref single 2) 20.0)

;; a second carry to the same place joins the destination's stock
(define twice
  (world (lambda (obs scope)
           (enact-rows scope (append (pair-rows "run1" 20.0) (pair-rows "run2" 15.0)))
           (totals obs))))
(check "two carries to one place: total conserved"     (list-ref twice 0) 100.0)
(check "…and the destination's stock is their sum"     (list-ref twice 2) 35.0)

;; a dropoff with no pickup behind it is refused, never half-recorded
(define refused
  (world (lambda (obs scope)
           (let* ((rows (pair-rows "run3" 5.0))
                  (threw (catch #t
                           (lambda () (record-flow-done scope (cadr rows)) #f)
                           (lambda _ #t))))
             (list threw (spec-total obs "water"))))))
(check "a dropoff before its pickup throws"            (list-ref refused 0) #t)
(check "…and leaves the stock whole"                   (list-ref refused 1) 100.0)

;; ── a whole planned carry, enacted ────────────────────────────────────────────
;; The engine's own located solve carries 100 L from A to B (stock at A, demand at B);
;; plan->material emits the pickup and dropoff rows, and enacting them against an observer that
;; holds the same crate must conserve the spec and land the water at B.
(use-modules (localchimera solve engine) (localchimera solve report) (localchimera solve world) (localchimera solve compile) (localchimera solve solver))
(define E (resolve-module '(localchimera solve engine)))
(declare-world! #:places '(("A" 0.0 0.0) ("B" 0.0 0.05)) #:templates '() #:movable '("water"))
(hash-set! *init* (lg "water" (cell "A" 0)) 100.0)
(hash-set! *demand* (lg "water" (cell "B" 0)) 30.0)
(define planned-mat
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let ((x (car (call-with-values (lambda () (solve-osqp forms labform ncol)) list))))
        ((@ (localchimera solve report) plan->material) x cols idx)))))
(define (carry? m) (memq (commitment-action m) '(pickup dropoff)))
(define moves (filter carry? planned-mat))
(display "\n── a planned carry, enacted ──\n")
(check "the plan carries the water with a pickup and a dropoff" (map commitment-action (sort moves (lambda (a b) (eq? (commitment-action a) 'pickup)))) '(pickup dropoff))
(define (row m)                       ; the wire shape the doors hand the books
  `((id . ,(commitment-id m)) (action . ,(commitment-action m)) (conforms-to . ,(commitment-resource-conforms-to m))
    (quantity . ,(row-figure m))
    (at-location . ,(commitment-at-location m)) (input-of . ,(commitment-input-of m)) (output-of . ,(commitment-output-of m))
    (note . ,(commitment-note m))))
(define enacted
  (world (lambda (obs scope)
           (enact-rows scope (map row moves))
           (totals obs))))
(check "after enaction the spec's total is conserved"  (list-ref enacted 0) 100.0)
(check "the demand's place holds the carried water"    (> (list-ref enacted 2) 29.0) #t)

;; ── a commitment's id names the flow it commits ───────────────────────────────
;; A re-solve that restates a flow restates the same commitment (the id carries the
;; action, spec, process, places and instant), so enacting the plan twice moves the
;; stock once and a restated quantity under a used id is refused, never silently
;; applied beside the first.
(define (solve-moves demand)
  (declare-world! #:places '(("A" 0.0 0.0) ("B" 0.0 0.05)) #:templates '() #:movable '("water"))
  (hash-set! *init* (lg "water" (cell "A" 0)) 100.0)
  (hash-set! *demand* (lg "water" (cell "B" 0)) demand)
  (filter carry?
          (call-with-values build-located
            (lambda (forms labform ncol cols goods raws idx)
              (let ((x (car (call-with-values (lambda () (solve-osqp forms labform ncol)) list))))
                ((@ (localchimera solve report) plan->material) x cols idx))))))
(define moves-a (solve-moves 30.0))
(define moves-b (solve-moves 30.0))
(display "\n── ids name the flow ──\n")
(check "a re-solve restates the flow under the same id"
       (equal? (map commitment-id moves-a) (map commitment-id moves-b)) #t)
(check "two flows of one plan never share an id"
       (= (length (delete-duplicates (map commitment-id moves-a))) (length moves-a)) #t)
(define twice
  (world (lambda (obs scope)
           (enact-rows scope (map row moves-a))
           (enact-rows scope (map row moves-b))   ; the re-solved plan, enacted again
           (list (spec-total obs "water") (spec-total obs "water" #:place "B")))))
(check "enacting the plan twice moves the stock once: total conserved" (list-ref twice 0) 100.0)
(check "…and the destination holds one carry, not two"                 (< (abs (- (list-ref twice 1) 30.0)) 1.0) #t)
(define restated (solve-moves 31.0))
(define refused
  (world (lambda (obs scope)
           (enact-rows scope (map row moves-a))
           (let ((unmet (cdr (enact-rows scope (map row restated)))))   ; a refusal waits; nothing records
             (list (pair? unmet) (spec-total obs "water"))))))
(check "a restated quantity under a used id is refused"  (list-ref refused 0) #t)
(check "…and the stock still totals 100"                 (list-ref refused 1) 100.0)

(test-summary!)

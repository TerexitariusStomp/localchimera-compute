;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-property-credit.scm — credit invariants over random communes.
;;;
;;; For fifteen seeded communes (two to five citizens, their hours and contribution
;;; factors random, a pool of bread of random size) the ledger keeps what it promises:
;;;   K0  no citizen's drawable credit is negative, at any free-time level;
;;;   K1  Σ drawable credit is the pool as it stands (the entitlement pool: the
;;;       claimable pool plus what has been claimed out of it, shared out whole);
;;;   K2  a claim the balance covers is admitted, takes exactly its cost from the
;;;       claimant's drawable credit and moves nobody else's, and Σ drawable credit
;;;       is again the pool as it stands (the pool fell by the cost);
;;;   K3  a claim past one's balance is refused.
;;; The seeds are fixed, so a failure is a world someone can build again.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/pools/test-property-credit.scm
(use-modules ((localchimera utils units) #:select (%count-unit %effort-unit)))
(use-modules (localchimera test harness) (localchimera algorithms elastic) (localchimera pools credit-fold)
             (localchimera scope root) (localchimera vf schemas) (localchimera observation states)
             ((localchimera observation account) #:select (declare-claimable!))
             ((localchimera test scope) #:select (plan-claim! record-work!))
             (goblins) (goblins persistence-store memory) (goblins utils hashmap) (srfi srfi-1) (srfi srfi-11) (ice-9 format))
(declare-claimable! "spec-bread")
(define N 15)
(define SEED0 1)
(define (rnd st n) (random n st))
(define (approx= a b) (< (abs (- a b)) 1e-6))
(define bad 0)
(define (verdict seed name ok . detail)
  (check name (and ok #t) #t)
  (unless ok (set! bad (+ bad 1)) (format #t "    seed ~a: ~s~%" seed detail)))

(define (one seed)
  (let*-values (((st) (seed->random-state seed))
                ((vat scope) (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root (format #f "C~a" seed))) (make-memory-store))))
    (with-vat vat
      (let* ((obs ($ scope 'observer)) (as ($ scope 'account-store)) (rs ($ scope 'recipe-store))
             (n (+ 2 (rnd st 4)))
             (aids (map (lambda (i) (format #f "c~a" i)) (iota n)))
             (loaves (+ 6 (rnd st 20))))
        (for-each (lambda (aid i)
                    (let ((h (+ 5 (rnd st 36))))
                      (record-work! obs aid h (format #f "e~a" i) (format #f "i~a" i))
                      ($ as 'credit-from-event ($ obs 'get-event (format #f "e~a" i)))
                      (when (= 0 (rnd st 3)) (account! as aid (list-ref '(1/2 3/4) (rnd st 2))))))
                  aids (iota n))
        ($ rs 'add-recipe-process (make-recipe-process #:id "rp-bake" #:name "Bake" #:process-conforms-to "pspec-bake" #:has-duration (make-duration 3 %effort-unit)))
        ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-w" #:action 'work #:resource-conforms-to "spec-labor" #:effort-quantity (make-measure 3 %effort-unit) #:recipe-input-of "rp-bake"))
        ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-o" #:action 'produce #:resource-conforms-to "spec-bread" #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-bake"))
        ($ rs 'add-recipe (make-recipe #:id "recipe-bread" #:name "Bread" #:primary-output "spec-bread" #:recipe-processes (list "rp-bake")))
        ($ obs 'record-event
           (make-economic-event #:id "ev-bread" #:action 'produce #:resource-inventoried-as "r-bread" #:resource-conforms-to "spec-bread"
                                #:resource-classified-as (list "individually-claimable") #:provider "commune" #:receiver "commune"
                                #:resource-quantity (make-measure loaves %count-unit) #:has-point-in-time "2026-03-02T12:00:00Z"))
        (let* ((pool (lambda () (global-embodied-labor-in-pool (list scope))))
               (bal (lambda (aid f) (global-effective-balance aid (list scope) #f f)))
               (total (lambda (f) (fold + 0 (map (lambda (a) (bal a f)) aids)))))
          (for-each (lambda (f)
                      (verdict seed (format #f "K1 f=~a: Σ drawable = the pool" f) (approx= (total f) (pool)) (list (total f) (pool)))
                      (verdict seed (format #f "K0 f=~a: no drawable is negative" f) (every (lambda (a) (>= (bal a f) -1e-9)) aids)
                               (map (lambda (a) (bal a f)) aids)))
                    '(0 1/4 1/2 1))
          ;; claims: a random citizen claims what their balance covers; the others are untouched
          (let loop ((k 0) (claimed '()))
            (when (< k (min 3 n))
              (let* ((who (let pick ((c (list-ref aids (rnd st n)))) (if (member c claimed) (pick (list-ref aids (rnd st n))) c)))
                     (b (bal who 0)) (q (max 1 (inexact->exact (floor (/ b 3.0))))) (q (min q 2))
                     (cost (* 3 q)))
                (when (and (>= b cost) (>= (pool) cost))
                  (let ((before (map (lambda (a) (cons a (bal a 0))) aids)) (pool0 (pool)))
                    (let ((r (catch #t (lambda () ($ as 'claim "r-bread" q who cost (list scope) #:fulfills (plan-claim! obs "spec-bread" who q))) (lambda (k . a) (list 'refused k (if (pair? a) (if (and (pair? (cdr a)) (string? (cadr a))) (list (cadr a) (if (pair? (cddr a)) (caddr a) '())) a) a))))))
                      (verdict seed "K2 an affordable claim is admitted" (eq? r #t) (list r who b cost))
                      (when (eq? r #t)
                        (let ((after (map (lambda (a) (cons a (bal a 0))) aids)))
                          (verdict seed "K2 the claimant's drawable falls by exactly the cost"
                                   (approx= (- (assoc-ref before who) (assoc-ref after who)) cost)
                                   (list who (assoc-ref before who) (assoc-ref after who) cost))
                          (verdict seed "K2 nobody else's drawable moves"
                                   (every (lambda (a) (or (equal? a who) (approx= (assoc-ref before a) (assoc-ref after a)))) aids)
                                   (list before after))
                          (verdict seed "K2 Σ drawable is the pool as it stands (the pool fell by the cost)"
                                   (and (approx= (pool) (- pool0 cost)) (approx= (total 0) (pool)))
                                   (list pool0 (pool) (total 0) cost)))))))
                (loop (+ k 1) (cons who claimed)))))
          ;; K3 a claim past one's balance is refused
          (let* ((who (car aids)) (b (bal who 0)) (q (+ 1 (inexact->exact (ceiling (/ b 3.0))))))
            (when (<= (* 3 q) (pool))
              (let ((r (catch #t (lambda () ($ as 'claim "r-bread" q who (* 3 q) (list scope) #:fulfills (plan-claim! obs "spec-bread" who q))) (lambda (k . a) 'refused))))
                (verdict seed "K3 a claim beyond the balance is refused" (not (eq? r #t)) (list r who b q))))))))))

(for-each (lambda (k) (catch #t (lambda () (one (+ SEED0 k)))
                         (lambda (key . args) (set! bad (+ bad 1)) (format #t "seed ~a raised ~s ~s~%" (+ SEED0 k) key args))))
          (iota N))
(test-summary!)

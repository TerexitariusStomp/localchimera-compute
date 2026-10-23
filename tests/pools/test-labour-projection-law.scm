;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-labour-projection-law.scm — the projection IS a per-key homomorphism.
;;;
;;; The law (labour-fold.scm, "the projection, stated as a per-key
;;; homomorphism"): over the commutative fragment of the event monoid,
;;;
;;;     project (fold log)  =  baseline ⊕ merge (deltas)
;;;
;;; Four claims, each held here:
;;;   1. HOMOMORPHISM  the observer's folded on-hand per (agent . spec) equals
;;;      the seeded baseline plus the keyed sum of the events' deltas
;;;   2. ORDER-FREE    permuting the commutative events changes neither side
;;;   3. THRESHOLD     the roster's held-set (skill-specs-for-agent) is
;;;      exactly the keys whose sum stands above zero — the read on top of
;;;      the homomorphism, not part of it
;;;   4. CONFINEMENT   an event outside the fragment (a produce on the same
;;;      resource) maps to #f — it stays where the log's total order lives
;;;
;;; Run:  guile --no-auto-compile -q -L module \
;;;         -l tests/pools/test-labour-projection-law.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet knowledge dsl shorthand)
             (playnet test harness)
             (playnet observation observer) (playnet vf schemas)
             (playnet pools labour-fold)
             (playnet observation observer)
             (playnet vf aggregation fold-node)
             ((playnet vf formulas actions) #:select (labour?))
             (goblins)
             (srfi srfi-1))

;; what labour is here — the recipes' word (formulas/actions labour?); a bare
;; observer has no store, so the suite states it: cook and weld are worked
(define labour-here
  (labour? (list (make-recipe-flow #:id "w1" #:action 'work #:resource-conforms-to "cook")
                 (make-recipe-flow #:id "w2" #:action 'work #:resource-conforms-to "weld"))
           '()))

(define (skill-resource rid spec aid q)
  (er rid spec aid #:name rid #:place #f #:qty q #:unit %count-unit #:tags #f))

(define (skill-event id action rid spec aid q)
  (make-economic-event
   #:id id #:action action #:resource-inventoried-as rid #:resource-conforms-to spec #:provider aid #:receiver aid
   #:resource-quantity (make-measure q %count-unit) #:has-point-in-time "2026-08-20T12:00:00Z" #:created "2026-08-20T12:00:00Z" #:note "law test"))

(define vat (spawn-vat))

(with-vat vat

  ;; baseline: ana holds cook (1) and weld (1)
  (define baseline '((("ana" . "cook") . 1) (("ana" . "weld") . 1)))
  (define (fresh-observer)
    (let ((obs (spawn ^observer (empty-observer-state) '())))
      ($ obs 'seed-resource (skill-resource "skill:ana:cook" "cook" "ana" 1))
      ($ obs 'seed-resource (skill-resource "skill:ana:weld" "weld" "ana" 1))
      obs))

  ;; the commutative log: raises and lowers on the two skills
  (define log
    (list (skill-event "e1" 'raise "skill:ana:cook" "cook" "ana" 2)
          (skill-event "e2" 'lower "skill:ana:weld" "weld" "ana" 1)
          (skill-event "e3" 'lower "skill:ana:cook" "cook" "ana" 1)
          (skill-event "e4" 'raise "skill:ana:cook" "cook" "ana" 3)))

  (define (project obs)          ; the fold of the log, read back per key
    (map (lambda (rid.spec)
           (let ((r ($ obs 'get-resource (car rid.spec))))
             (cons (cons "ana" (cdr rid.spec))
                   (measure-has-numerical-value
                    (economic-resource-onhand-quantity r)))))
         '(("skill:ana:cook" . "cook") ("skill:ana:weld" . "weld"))))

  (define (replay! obs evs) (for-each (lambda (e) ($ obs 'record-event e)) evs))

  (define (sorted cells)
    (sort cells (lambda (a b) (string<? (cdar a) (cdar b)))))

  (display "\n── 1. project (fold log) = baseline ⊕ merge (deltas) ──\n")
  (define obs-a (fresh-observer))
  (replay! obs-a log)
  (check "the two sides agree per key"
         (sorted (project obs-a))
         (sorted (sum-by-key baseline (skill-count-deltas log labour-here))))
  (check "and say what they should: cook 5, weld 0"
         (sorted (project obs-a))
         '((("ana" . "cook") . 5) (("ana" . "weld") . 0)))

  (display "\n── 2. the commutative fragment is order-free ──\n")
  (define obs-b (fresh-observer))
  (replay! obs-b (reverse log))
  (check "a permuted log folds to the same state"
         (sorted (project obs-b)) (sorted (project obs-a)))
  (check "and the deltas merge to the same sum"
         (sorted (skill-count-deltas (reverse log) labour-here))
         (sorted (skill-count-deltas log labour-here)))

  (display "\n── 3. held-ness is the threshold read on top ──\n")
  (check "the roster keeps exactly the keys above zero"
         (skill-specs-for-agent obs-a "ana" labour-here) '("cook"))
  (check "either replay order, same roster"
         (skill-specs-for-agent obs-b "ana" labour-here) '("cook"))

  (display "\n── 4. outside the fragment: no delta, scope-local only ──\n")
  (check "a produce on the same resource has no homomorphic image"
         (skill-onhand-delta
          (skill-event "e5" 'produce "skill:ana:cook" "cook" "ana" 1) labour-here)
         #f)
  (check "a raise on a non-skill resource has none either"
         (skill-onhand-delta
          (skill-event "e6" 'raise "means:ana:oven" "oven" "ana" 1) labour-here)
         #f))

(test-summary!)

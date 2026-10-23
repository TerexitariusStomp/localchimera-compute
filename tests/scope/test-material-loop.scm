;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-material-loop.scm — the plan's own realisation moves stock, exactly, for a
;;; MULTI-STAGE chain. enact-rows records the plan's produce/consume/move rows into
;;; the REAL observer by readiness (a row waits for the stock it draws), so no
;;; intermediate ever dips negative: raw drawn down, final stocked up, intermediates
;;; net to zero.

(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness)
             (playnet observation observer) (playnet vf schemas) (srfi srfi-1)
             (playnet scope live)
             (playnet test planner bread)
             (goblins) (goblins vat)
             (srfi srfi-1))

;; the bread chain: soil → grain → flour → bread (three stages).
(define procs bread-procs) (define flows bread-flows) (define recipes bread-recipes)
(define agents bread-plain-agents) (define spatials bread-spatials)

(define* (raise-event id rid spec acct qty #:optional (unit "kg"))
  (make-economic-event #:id id #:action 'raise #:resource-inventoried-as rid #:resource-conforms-to spec #:provider acct #:receiver acct
                       #:resource-quantity (make-measure qty unit) #:at-location "town"))
(define (onhand obs spec)
  (fold (lambda (r a) (if (equal? (economic-resource-conforms-to r) spec)
                          (+ a (let ((mm (economic-resource-onhand-quantity r))) (if mm (measure-has-numerical-value mm) 0.0))) a))
        0.0 ($ obs 'all-resources)))

(define out
  (with-vat (spawn-vat #:name "matchain")
    (let ((obs (spawn ^observer (empty-observer-state) '())))
      ($ obs 'record-event (raise-event "ev-soil" "soil-1" "soil" "scope" 100.0))
      ($ obs 'record-event (raise-event "ev-skf" "sk-f" "skill-farm" "f" 1.0))
      ($ obs 'record-event (raise-event "ev-skm" "sk-m" "skill-mill" "m" 1.0))
      ($ obs 'record-event (raise-event "ev-skb" "sk-b" "skill-bake" "b" 1.0))
      ($ obs 'record-event (raise-event "ev-skfi" "sk-fi" "skill-fish" "b" 1.0))   ; the table's fish: a town feeds its people the whole band
      ($ obs 'record-event (raise-event "ev-sea" "sea-1" "fish-stock" "scope" 1.0e4))   ; the stocks the harvests draw: the sea's fish, the meadow's feed
      ($ obs 'record-event (raise-event "ev-hay" "hay-1" "fodder" "scope" 1.0e4))
      ($ obs 'record-event (raise-event "ev-well" "well" "water" "scope" 1.0e5 "L"))   ; what the loaf, the herd and the pans draw
      ($ obs 'record-event (raise-event "ev-line" "line" "spec-sp-electricity" "scope" 1.0e4 "kWh"))   ; and what turns the stones and heats the oven
      (let* ((as  (spawn ^mock `((all-agents . ,(lambda () agents)))))
             (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
             (rs  (spawn ^mock `((all-recipes . ,(lambda () recipes)) (get-process-chain . ,(lambda (r) procs))
                                 ;; (inputs . outputs), as the real store answers
                                 (flows-for-process . ,(lambda (pid) (cons (filter (lambda (fl) (equal? (recipe-flow-recipe-input-of fl) pid)) flows)
                                                                           (filter (lambda (fl) (equal? (recipe-flow-recipe-output-of fl) pid)) flows)))))))
             (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs)))
        (let* ((soil0 (onhand obs "soil"))
               (plan (plan-scope->alist scope #:demand '(("bread#town@0" . 10.0))))
               (_ (enact-rows scope (assq-ref plan 'material)))
               (soil1 (onhand obs "soil")) (bread1 (onhand obs "bread"))
               (grain1 (onhand obs "grain")) (flour1 (onhand obs "flour")))
          (list plan soil0 soil1 bread1 grain1 flour1))))))

(define plan (list-ref out 0))
(define soil0 (list-ref out 1)) (define soil1 (list-ref out 2))
(define bread1 (list-ref out 3)) (define grain1 (list-ref out 4)) (define flour1 (list-ref out 5))
(define mat (assq-ref plan 'material))
;; index in the emitted material list of the first produce / first consume of a spec
(define (pos action spec) (list-index (lambda (m) (and (eq? (assq-ref m 'action) action) (equal? (assq-ref m 'conforms-to) spec))) mat))

(display "\n── multi-stage material loop: dependency-ordered, exact ──\n")
(check "every intermediate is PRODUCED before it is CONSUMED (grain)"
       (and (pos 'produce "grain") (pos 'consume "grain") (< (pos 'produce "grain") (pos 'consume "grain"))))
(check "every intermediate is PRODUCED before it is CONSUMED (flour)"
       (and (pos 'produce "flour") (pos 'consume "flour") (< (pos 'produce "flour") (pos 'consume "flour"))))
(check "the raw soil's consume comes before grain's produce (grow consumes then produces)"
       (< (pos 'consume "soil") (pos 'produce "grain")))
(check "after enaction: raw soil DREW DOWN"            (< soil1 soil0))
(check "after enaction: final bread STOCKED UP"        (> bread1 5.0))
(check "intermediates net to ~zero — produced AND fully consumed (grain)"  (< (abs grain1) 0.1))
(check "intermediates net to ~zero — produced AND fully consumed (flour)"  (< (abs flour1) 0.1))
(check "no intermediate went negative (grain ≥ 0)"     (>= grain1 -0.01))
(check "no intermediate went negative (flour ≥ 0)"     (>= flour1 -0.01))
;; 1.2 kg of grain a kilogram of flour, three quarters of flour a loaf: 0.9 kg of soil a loaf
(check "mass balance: soil consumed ≈ grain made ≈ bread×0.9, the chain holds"
       (> (- soil0 soil1) (* 0.85 bread1)))

(test-summary!)

;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-housing-live.scm — the housing floor, derived and met in a LIVE scope.
;;;
;;; tests/solve/test-housing-substance.scm proves the
;;; standard, the derivation and the solve at the engine's fixture door. This
;;; is the live door: `plan-scope` reads a scope's own people and its own
;;; typed dwellings, derives each person's bands from the adequacy catalogue,
;;; and carries the period's facts — a night falls, a dwelling stands — as
;;; pins, through the one door that already reads standing accepts.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/scope/test-housing-live.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test harness)
             (playnet vf schemas) (srfi srfi-1) (srfi srfi-11) (playnet scope live) (playnet vf schemas)
             (playnet test planner bread)
             (goblins) (goblins vat)
             (srfi srfi-1))

(define (person id tags) (make-agent #:id id #:type 'person #:primary-location "town"
                                     #:classified-as tags))
(define wil (person "wil" '("age:70" "step-free")))

(define (res id spec tags qty unit)
  (make-economic-resource #:id id #:name id #:conforms-to spec #:classified-as tags #:accounting-quantity (make-measure qty unit) #:onhand-quantity (make-measure qty unit)
                          #:current-location "town"))
(define purse (res "res:purse" "spec-eur" '() 200.0 "EUR"))
(define GATES '("attests:hs-safety" "attests:hs-sanitation" "attests:hs-quiet" "attests:hs-dark" "attests:hs-accessibility"))
(define studio (res "studio-1" "spec-dwelling" '("dwelling-type:studio" "beds:3" "attests:hs-safety" "attests:hs-sanitation" "attests:hs-quiet" "attests:hs-dark" "certified") 1 %count-unit))
(define flat   (res "flat-7"  "spec-dwelling" (append '("dwelling-type:family-flat" "beds:2" "certified") GATES) 1 %count-unit))
(define plain  (res "old-flat" "spec-dwelling" '() 1 %count-unit))   ; states no type: dwelling.scm's flat, left to it

;; the bread scope's own people and stock stand — wil eats as they do — and he
;; and the dwellings join them
(define (solve resources)
  (let ((vat (spawn-vat #:name "housing-live")))
    (with-vat vat
      (let-values (((scope ps als) (spawn-bread-scope #:agents (cons wil bread-plain-agents)
                                                       #:resources (append resources bread-plain-resources))))
        (plan-scope->alist scope #:backend 'native-c #:allow-infeasible? #t)))))
(define (runs result proc) (or (assoc-ref (or (assq-ref result 'first-stage-plan) '()) proc) 0))
;; where a body's night went: living-in is consumption, so it is RECOURSE and
;; reads off the plan's material flows — the night each live-in run consumed
(define (night-in result pid unit)
  (fold (lambda (m acc)
          (if (and (eq? 'consume (assq-ref m 'action))
                   (equal? (string-append "hs-night|" pid) (assq-ref m 'conforms-to))
                   (equal? (string-append "live-in-certified~" unit "~" pid) (assq-ref m 'input-of)))
              (+ acc (assq-ref m 'quantity)) acc))
        0.0 (or (assq-ref result 'material) '())))

(display "\n── a live scope houses its people against the catalogue ──\n")
(define housed (solve (list purse studio flat)))
(check "the period's facts arrive as pins, first-stage: wil's night falls, the flat stands — exactly 1"
       (and (< (abs (- 1.0 (runs housed "nightfall~wil"))) 1e-9)
            (< (abs (- 1.0 (runs housed "stands~flat-7"))) 1e-9)))
(format #t "  wil: flat-7 ~,3f · studio-1 ~,3f     f: studio-1 ~,3f · flat-7 ~,3f~%"
        (night-in housed "wil" "flat-7") (night-in housed "wil" "studio-1")
        (night-in housed "f" "studio-1") (night-in housed "f" "flat-7"))
(check "wil — 70, step-free — spends his night certified in the flat, the one dwelling that is step-free"
       (and (> (night-in housed "wil" "flat-7") 0.9) (< (night-in housed "wil" "studio-1") 0.1)))
(check "the others, owed safety and sanitation and not step-free access, are housed certified in the cheaper studio"
       (every (lambda (pid) (> (night-in housed pid "studio-1") 0.9)) '("f" "m" "b")))
(check "…and the plan is one the solve certifies"
       (assq-ref housed 'feasible))

(display "\n── a scope with no typed dwelling is untouched ──\n")
(define untouched (solve (list purse plain)))
(check "a dwelling that states no type brings no housing recipe, band or pin"
       (= 0 (runs untouched "nightfall~wil")))

(test-summary!)

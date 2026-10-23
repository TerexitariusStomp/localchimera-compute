;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; catalogues/insurance.scm — the INSURANCE reserve, governed: q_r^res = ι_r · q_r^*.
;;;
;;; playnet.typ §Reproduction labour: a stock's standing level has two parts — the
;;; soft desired quantity q* (a want, with its buffer) and the HARD insurance
;;; reserve q^res, "the third deduction, sized by the computation of calamity
;;; probabilities, in no way calculable by equity", held as a possibility-tension.
;;; §Possibility-tensions: "the same registered curve that prices a live limit
;;; also sets, per (category, resource), the insurance-rate ι_r — how large a
;;; calamity reserve to hold behind the good, and how steeply to defend it as it
;;; empties. Sizing the insurance fund and pricing a fragility are one governance
;;; act."
;;;
;;; So the reserve is a governed DATUM, not a kwarg a caller invents: one row per
;;; resource category, ratified like every planetary boundary. This is the
;;; insurance twin of conformance-catalogue.scm (which governs the inspection
;;; barrier's steepness) and of catalogues/subsistence.scm (which governs the
;;; nutrient bands): plain defines, primitive-load-able, read by the live solve
;;; (plan-scope #:insure? → #:insurance rows) and by nothing else.
;;;
;;; a row: (spec iota margin alpha w "source")
;;;   spec    the resource the reserve stands behind (a food, a fuel, a medicine…)
;;;   iota    the insurance RATE: q^res = iota · q*, q* the desired quantity (the
;;;           good's #:demand at that cell) — the reserve scales with the want
;;;   margin  the comfort held above the calamity level: hi = lo · (1 + margin)
;;;   alpha   where in [lo,hi] the plan is at ease (a floor: more is precautious)
;;;   w       steepness — how hard the margin is defended as it erodes
;;; The row becomes a `held` floor with a margin in the good's reproduction band
;;; (planner.scm *band*): divergent at lo = iota·q*, so the calamity stock is never
;;; breached; satiating at quantile_alpha of [lo,hi], so nothing is over-made for it.
;;;
;;; DRAFT figures — to be ratified at the UC level, like every other catalogue number.

;; ── the catalogue ────────────────────────────────────────────────────────────
(define-module (playnet knowledge catalogues insurance)
  #:use-module (srfi srfi-1)
  #:export (*insurance-catalogue* ins-spec ins-iota ins-margin ins-alpha ins-w
            insurance-row insurance-profile insurance-rows reserve-report
            reserve-controls))

(define *insurance-catalogue*
  (list
   ;; a season's food: a quarter of the desired quantity held back as calamity
   ;; stock, a further 30% of comfort above it, defended at the nutrient bands' own
   ;; steepness. The Doon record (worlds/doon-valley.scm) puts the famine tail at ~15% of
   ;; a normal harvest; a quarter of the want is the order the granary test banks.
   '("food" 0.25 0.30 0.5 5.0
     "DRAFT — a quarter-season calamity stock behind food; ratify at UC (playnet.typ §Reproduction labour, q^res = ι·q*)")))

(define (ins-spec r)   (list-ref r 0))
(define (ins-iota r)   (list-ref r 1))
(define (ins-margin r) (list-ref r 2))
(define (ins-alpha r)  (list-ref r 3))
(define (ins-w r)      (list-ref r 4))

;; the row for a bare spec, or #f — a good with no governed reserve carries none
(define* (insurance-row spec #:optional (catalogue *insurance-catalogue*))
  (find (lambda (r) (equal? (ins-spec r) spec)) catalogue))

;; the reserve behind a good WANTED at q*: the `held` profile (lo hi alpha w), or #f.
;; lo = ι·q* is the calamity level; hi = lo·(1+margin) the comfort above it.
(define* (insurance-profile spec q* #:optional (catalogue *insurance-catalogue*))
  (let ((r (insurance-row spec catalogue)))
    (and r (> q* 0.0)
         (let ((lo (* (ins-iota r) q*)))
           (list lo (* lo (+ 1.0 (ins-margin r))) (ins-alpha r) (ins-w r))))))

;; the #:insurance rows for a plan: one per DEMANDED located good whose spec has a
;; governed reserve — ((located-good lo hi alpha w) …). demand = ((located-good .
;; q*) …), keyed "spec#place@period"; the reserve stands at the same cell as the
;; want it is sized from. Pure: the same demand and catalogue give the same rows.
(define* (insurance-rows demand #:optional (catalogue *insurance-catalogue*))
  (filter-map
   (lambda (d)
     (let* ((g (car d)) (i (string-index g #\#))
            (spec (if i (substring g 0 i) g))
            (p (insurance-profile spec (cdr d) catalogue)))
       (and p (cons g p))))
   demand))

;; the reserve rows a plan REPORTS — the cell's tab: (g q* q^res target level), the
;; standing level q* + q^res the good aims at and the level the plan actually holds
;; there. `level-of` reads the solved on-hand of a located good AS THE SOLVER SEES
;; IT — the reserve already taken off (apply-repro-bands!: a need before a want),
;; so the standing level is that remainder plus the reserve.
(define (reserve-report rows demand level-of)
  (map (lambda (r)
         (let* ((g (car r)) (lo (cadr r)) (q* (or (assoc-ref demand g) 0.0)))
           `((good . ,g) (desired . ,q*) (reserve . ,lo) (target . ,(+ q* lo))
             (level . ,(+ lo (level-of g))) (w . ,(list-ref r 4)))))
       rows))

;; the tab as the fragility wheel reads it — one control per reserved good, in the
;; wire's own shape (spec kind control group unit w source current tip s): the
;; wall is the reserve, the plateau the target, and the slack the ROOM the plan
;; holds above the calamity stock — 1 at the target (the want met on top of the
;; reserve), → 0 at the wall (the want gone, the reserve intact). The same reading
;; the solver made, so the wheel shows what the plan held, not a constant.
(define (reserve-controls tab)
  (map (lambda (r)
         (let* ((g (assq-ref r 'good)) (i (string-index g #\#))
                (spec (if i (substring g 0 i) g))
                (lo (assq-ref r 'reserve)) (target (assq-ref r 'target)) (level (assq-ref r 'level))
                (room (- target lo))
                (s (max 1e-3 (min 1.0 (if (> room 0.0) (/ (- level lo) room) 1.0)))))
           `((spec . ,g) (kind . "reserve") (control . ,spec) (group . "reserve")
             (unit . "on hand") (w . ,(assq-ref r 'w))
             (source . "the calamity stock behind the good — q^res = ι·q*, catalogues/insurance.scm; the want stands above it")
             (current . ,level) (tip . ,lo) (target . ,target) (s . ,s))))
       tab))

;; standalone demo — runs only when this file IS the script being run, which the
;; current-filename check already decides on its own. It used to also test
;; PLANNER_LIB, from when the engine printed its demos on load and every caller
;; had to say so; the engine is a library now (see demo.scm) and nothing sets it.
;; run as a program on a host; a page loads this as a library only
(cond-expand
 (guile
  (when (equal? (current-filename)
                (and (pair? (command-line)) (car (command-line))))
    (display "\ninsurance catalogue: ") (display (length *insurance-catalogue*)) (display " row(s)\n")
    (display "  food wanted 1000 → held profile ") (display (insurance-profile "food" 1000.0)) (newline)))
 (else))

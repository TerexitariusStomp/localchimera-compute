;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-limit-migration.scm — the four constrained limits, carried as stocks.
;;;
;;; A fragility says "you have this much left" with a prior that only rises. A
;;; regenerating stock says the same thing as a LEVEL, and a level can be rebuilt.
;;; Migrating costs the drawing side nothing — recipes already `consume` the spec,
;;; so the same flows that spent headroom against a barrier now spend it against a
;;; stock. What the migration adds is the other direction.
;;;
;;; The witnessed character (witness table 3) does not stay a label a classifier
;;; reads; it BECOMES the mechanism:
;;;
;;;   nitrogen   reversible (~30 yr)               → nature attenuates, briskly
;;;   phosphorus slowly-reversible (~200 yr)       → nature attenuates, ~7× slower
;;;   warming    reversible-with-removal (~100 yr) → nature returns NOTHING; the
;;;   ocean-acid reversible-with-removal (~100 yr)   Zero Emissions Commitment is
;;;                                                  ~0, so only removal labour
;;;                                                  brings headroom back
;;;
;;; and an `irreversible` limit would yield no stock at all, staying a fragility
;;; where a rising prior is the honest shape.
;;;
;;; The catalogue supplies the stock and nature's share. It does NOT supply the
;;; removal recipe: what removal costs in hours is a technology fact a scope knows
;;; about its own plant, not something a planetary catalogue asserts for everyone.
;;; So removal enters as ordinary scope data, priced like any other recipe — which
;;; is what the last section here demonstrates.
;;;
;;; Run: guile --no-auto-compile -L module/playnet/planner \
;;;        tests/solve/test-limit-migration.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve plan)
             (playnet vf schemas)
             (playnet vf formulas stocks))
(use-modules (playnet knowledge catalogues eco)
             (playnet knowledge dsl shorthand))
;; A period here is a WEEK: the roster's 09:00–17:00 every day is 56 h a period,
;; the labour these limits were sized on, and the same on any date.
(set-period-length! 1.0 "week")

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define SEASONS '(0 1 2 3))

(let* ((ms        (migrated-limits *planetary-catalogue* #:place "earth" #:period-years 1.0))
       (stocks    (map migrated-stock ms))
       (procs     (migrated->procs ms))
       (flows     (migrated->flows ms))
       (storables (migrated->storables ms))
       (caps      (migrated->caps ms SEASONS)))

(format #t "~%── the four limits, migrated ──~%~%")
(format #t "  ~22a ~12a ~14a ~a~%" "spec" "headroom" "nature returns" "per year")
(format #t "  ~22a ~12a ~14a ~a~%" "────" "────────" "──────────────" "────────")
(for-each
 (lambda (s)
   (let* ((spec (rstock-spec s))
          (rate (limit-attenuation-rate spec (rstock-init s) 1.0)))
     (format #t "  ~22a ~12,3f ~14a ~a~%" spec (rstock-init s)
             (if rate "attenuation" "removal only")
             (if rate (format #f "~,4f ~a" rate (rstock-unit s)) "—"))))
 stocks)

(format #t "~%")
(check "all four constrained limits migrate to stocks"
       (= 4 (length stocks)))
(check "every migrated limit CARRIES in time (a level, not a rising prior)"
       (= 4 (length storables)))

;; The drawing side is untouched: a stock's spec is the SAME spec the recipes
;; already consume, so nothing in the recipe library changes to migrate a limit.
(check "the migration renames nothing — the stock's spec is the drawn spec"
       (every (lambda (s) (member (rstock-spec s)
                                  '("warming" "ocean-acidification" "nitrogen" "phosphorus")))
              stocks))

;; Character → mechanism. Only the two `reversible` limits get nature's process.
(check "nature attenuates nitrogen and phosphorus, and only those"
       (equal? '("nitrogen" "phosphorus")
               (sort (map (lambda (p) (substring (recipe-process-id p) (string-length "attenuate~")))
                          procs)
                     string<?)))
(check "warming and ocean-acidification get NO attenuation — removal is the only way back"
       (and (not (limit-attenuation-rate "warming" 1.0 1.0))
            (not (limit-attenuation-rate "ocean-acidification" 1.0 1.0))))

;; The rates are read off the citations, not chosen here: 1/30 vs 1/200 of the tip.
(let* ((n-tip 72.0) (p-tip 8.7)                     ; quantile_0.5 of [62,82] and [6.2,11.2]
       (n (limit-attenuation-rate "nitrogen" n-tip 1.0))
       (p (limit-attenuation-rate "phosphorus" p-tip 1.0)))
  (check "nitrogen's rate is its tip over its recorded 30 yr"
         (< (abs (- n (/ n-tip 30.0))) 1e-9))
  (check "phosphorus's rate is its tip over its recorded 200 yr"
         (< (abs (- p (/ p-tip 200.0))) 1e-9))
  (check "so phosphorus returns ~6.7× more slowly, per the sources and nothing else"
         (< (abs (- (/ (/ n n-tip) (/ p p-tip)) (/ 200.0 30.0))) 1e-9)))

;; Nature's return is a RATE, not a budget the plan may spend early: one
;; attenuation run per period, per limit.
(check "attenuation is gated per period, so it cannot be drawn forward"
       (= (* 2 (length SEASONS)) (length caps)))

;; ── the other half: removal is the SCOPE's recipe, and it is labour ──────────
;; A federation that wants headroom back faster than nature returns it staffs a
;; removal process. Here: nitrogen, with a future floor on remaining headroom.
(format #t "~%── removal as ordinary scope data: a floor on headroom, met by labour ──~%")
(let* ((place "earth")
       (n-stock (find (lambda (s) (equal? "nitrogen" (rstock-spec s))) stocks))
       (win (all-week-window "09:00" "17:00"))
       (agents (list (person* "ada" #:name "Ada" #:place place #:window win)))
       (spatials (list (place* place)))
       ;; the federation draws N to grow food, and can also SCRUB it back
       (fert  (rp* "fertilise" "Fertilise"))
       (scrub (rp* "scrub" "Effluent works"))
       (extra-procs (list fert scrub))
       (extra-flows
        (list (out* "fp" "food" 10.0 "fertilise")
              (stock-draw-flow "fd" "nitrogen" 1.0 "fertilise" "fixation draws the boundary")
              (wk* "fw" "skill-land" 0.5 "fertilise")
              ;; REMOVAL: real hours, returning headroom faster than nature
              (stock-restore-flow "sr" "nitrogen" 2.0 "scrub" "the federation's own hands")
              (wk* "sw" "skill-land" 4.0 "scrub")))
       (resources (list (er "sk" "skill-land" "ada" #:place place #:unit "kg")
                        (regenerating-stock->resource n-stock)))
       ;; enough food that fixation genuinely eats the boundary: 150 kg/season over
       ;; four seasons draws 60 of the 72 Tg headroom, against ~9.6 nature returns.
       (food-floors (map (lambda (t) (cons (format #f "food#~a@~a" place t) 150.0)) SEASONS))
       (n-floor (list (cons (format #f "nitrogen#~a@~a" place (last SEASONS))
                            (* 0.9 (rstock-init n-stock)))))
       (n-caps  (filter (lambda (c) (string-prefix? "attenuation~nitrogen" (car c))) caps))
       (n-procs (filter (lambda (p) (equal? "attenuate~nitrogen" (recipe-process-id p))) procs))
       (n-flows (filter (lambda (f) (string-prefix? "attenuate~nitrogen" (recipe-flow-id f))) flows))
       (run (lambda (floors)
              (call-with-values
                (lambda () (plan-from-records resources agents spatials
                             (append extra-procs n-procs) (append extra-flows n-flows)
                             #:periods SEASONS #:storable '("nitrogen")
                             #:eco-caps n-caps #:repro-floors floors
                             #:per-agent? #f #:backend 'native-c))
                (lambda (ints coms material fill cols x idx ntot report)
                  (let ((act (lambda (p t) (let ((i (hash-ref idx (format #f "p|~a|~a@~a" p place t) #f)))
                                             (if i (vector-ref x i) 0.0)))))
                    (list (* 4.0 (fold + 0.0 (map (lambda (t) (act "scrub" t)) SEASONS)))
                          (assq-ref (assq-ref report 'certificate) 'feasible?))))))))
  (let* ((without (run food-floors))
         (with-t  (run (append food-floors n-floor))))
    (format #t "  feed everyone only                    : ~,1f h of removal labour~%" (car without))
    (format #t "  …and hold 90% of the headroom by t=3  : ~,1f h of removal labour~%" (car with-t))
    (check "with no headroom target, the federation does not staff removal"
           (< (car without) (* 0.2 (max 1e-9 (car with-t)))))
    (check "a headroom target makes it SCHEDULE removal labour"
           (> (car with-t) 1.0))
    (check "…and the recovering plan is a real plan"
           (eq? #t (cadr with-t)))))

;; ── the guard: a level must never also be a cap ──────────────────────────────
;; The failure this catches is SILENT otherwise. A stock-frag spec whose level
;; routed to *cap* instead of *init* leaves the balance at const 0 — a perfectly
;; well-formed barrier that forbids all activity, and reads downstream exactly
;; like a plan that chose not to draw. That happens if the never-raw registration
;; lands after ingest-stock!, or if a caller declares the same limit twice.
(format #t "~%── the guard against a silently-zeroed level ──~%")
(let* ((n (find (lambda (x) (equal? "nitrogen" (migrated-spec x))) ms))
       (gprocs (list (rp* "g" "G")))
       (gflows (list (out* "go" "food" 10.0 "g")
                     (consume* "gn" "nitrogen" 1.0 "g" "unit")))
       (fired? (lambda (thunk)
                 (catch #t (lambda () (thunk) #f)
                        (lambda (k . a) (and (string-contains (format #f "~a ~a" k a) "stock-frag") #t))))))
  (check "a correctly registered level raises nothing"
         (not (fired? (lambda ()
                        (plan-from-records (migrated->resources (list n)) '()
                          (list (place* "earth")) gprocs gflows
                          #:stock-frag (migrated->stock-frag (list n)) #:backend 'native-c)))))
  (check "declaring the same limit as BOTH a level and a cap is refused, loudly"
         (fired? (lambda ()
                   (plan-from-records (migrated->resources (list n)) '()
                     (list (place* "earth")) gprocs gflows
                     #:stock-frag (migrated->stock-frag (list n))
                     #:eco-caps '(("nitrogen#earth@0" . 72.0)) #:backend 'native-c))))
  ;; the other diversion, found by auditing the seven fragility tables: a spec
  ;; given BOTH a level and a fragility profile routes its quantity to the prior,
  ;; and never-raw then puts the good where the fragility emission cannot reach it
  ;; — the barrier reads 0 AND the profile is dropped. Two silent losses at once.
  (check "declaring it as BOTH a level and a fragility profile is refused too"
         (fired? (lambda ()
                   (plan-from-records (migrated->resources (list n)) '()
                     (list (place* "earth")) gprocs gflows
                     #:stock-frag (migrated->stock-frag (list n))
                     #:eco-spec-frag '(("nitrogen" . (62.0 82.0 0.5 5.0))) #:backend 'native-c)))))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — every limit that returns is now carried where it can~%  be SEEN to return. Nature's share is a rate off the citations; the rest is~%  labour the federation schedules. Character became mechanism.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%"))

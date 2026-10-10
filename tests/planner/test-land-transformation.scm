;;; test-land-transformation.scm — leads and specifications, kept apart.
;;;
;;; knowledge/recipes/land-transformation-scales.scm holds two kinds of
;;; knowledge and the tests below check that they stay separate:
;;;
;;;   LEADS come from field documentation and say what EXISTS — a technique, a
;;;   site, a scale worth researching. They carry a timestamp and a research
;;;   thread, and they feed no flow.
;;;
;;;   SPECIFICATIONS come from FAO's 1991 design manual and say how big to dig.
;;;   Every quantity in the recipe is computed from these.
;;;
;;; The property under test is that no recipe quantity traces back to a
;;; narrator. If a lead ever grows a coefficient, the last test here fails.
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-land-transformation.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve compile)
             (playnet vf schemas))
(use-modules (playnet knowledge recipes land-transformation-scales))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
(define (near? a b tol) (< (abs (- a b)) tol))

(format #t "~%Leads (footage) and specifications (FAO 1991), kept apart~%~%")

;;; ── 1. Leads are research threads, not data ────────────────────────────────

(check "seven leads, household through region"
       (= 7 (length *land-transformation-leads*)))

(check "every lead cites where it was heard"
       (every (lambda (l) (let ((h (lead-ref (car l) 'heard)))
                            (and (string? h) (string-prefix? "[" h))))
              *land-transformation-leads*))

(check "every lead names a real site"
       (every (lambda (l) (string? (lead-ref (car l) 'site))) *land-transformation-leads*))

;; The point of a lead: it says where to go next.
(check "every lead carries a research thread to follow"
       (every (lambda (l) (string? (lead-ref (car l) 'research))) *land-transformation-leads*))

(check "every lead names the technique to look up"
       (every (lambda (l) (string? (lead-ref (car l) 'technique))) *land-transformation-leads*))

;; The observation worth keeping from the footage.
(define binds (map (lambda (l) (lead-ref (car l) 'binds)) *land-transformation-leads*))
(check "the constraint moves as scale grows: catchment, then labour, then reach"
       (and (eq? 'catchment (car binds))
            (eq? 'labour (list-ref binds 2))
            (eq? 'reach (last binds))))
(check "at least three distinct binding constraints appear"
       (>= (length (delete-duplicates binds)) 3))

;;; ── 2. Specifications carry everything a build needs ───────────────────────

(check "two FAO designs for the half-moon"
       (= 2 (length *earthwork-specs*)))

(check "every spec cites a manual section"
       (every (lambda (s) (string-prefix? "FAO" (cadr (assq 'cite (cdr s)))))
              *earthwork-specs*))

(check "every spec is dimensioned: radius, earthworks, density, slope limit"
       (every (lambda (s)
                (let ((k (car s)))
                  (and (number? (earthwork-ref k 'radius-m))
                       (number? (earthwork-ref k 'earthworks-ha-m3))
                       (number? (earthwork-ref k 'per-ha))
                       (number? (earthwork-ref k 'max-slope-pct)))))
              *earthwork-specs*))

;; The internal arithmetic of Table 21: soil per structure x structures per
;; hectare should land on the tabulated per-hectare figure. If a digit drifted
;; in transcription, this fails rather than propagating into a plan.
(check "small design: 2.4 m3 x 73 structures ≈ 175 m3/ha"
       (near? (* (earthwork-ref "semi-circular-bund-a" 'earthworks-m3)
                 (earthwork-ref "semi-circular-bund-a" 'per-ha))
              (earthwork-ref "semi-circular-bund-a" 'earthworks-ha-m3) 3.0))
(check "large design: 26.4 m3 x 4 structures ≈ 105 m3/ha"
       (near? (* (earthwork-ref "semi-circular-bund-b" 'earthworks-m3)
                 (earthwork-ref "semi-circular-bund-b" 'per-ha))
              (earthwork-ref "semi-circular-bund-b" 'earthworks-ha-m3) 3.0))

;; Why a specification beats a description: same technique, different budget.
(check "the two designs differ by 40% in soil moved per hectare"
       (> (/ (earthwork-ref "semi-circular-bund-a" 'earthworks-ha-m3)
             (earthwork-ref "semi-circular-bund-b" 'earthworks-ha-m3))
          1.4))

(check "catchment ratios stay within the manual's 3:1 rangeland guidance"
       (every (lambda (s) (<= (earthwork-ref (car s) 'c-ca) *max-rangeland-c-ca*))
              *earthwork-specs*))

(check "the design exceeding 1.4:1 is the one carrying an overflow"
       (eq? #t (earthwork-ref "semi-circular-bund-b" 'overflow)))

;;; ── 3. Slope selects the design ────────────────────────────────────────────

(check "at 0.5% slope both designs are valid, the cheaper is chosen"
       (equal? "semi-circular-bund-b" (earthwork-for-slope 0.5)))
(check "at 1.5% slope only the large design remains valid"
       (equal? "semi-circular-bund-b" (earthwork-for-slope 1.5)))
(check "above 2% the manual covers neither design"
       (not (earthwork-for-slope 3.0)))

;;; ── 4. Earthwork quantities scale, and ditches add to them ────────────────

(check "10 ha of the small design moves 1750 m3"
       (near? (earthworks-for-area "semi-circular-bund-a" 10.0) 1750.0 1.0))
(check "a 200 m diversion ditch adds 125 m3"
       (near? (- (earthworks-for-area "semi-circular-bund-a" 10.0 #:ditch-m 200.0)
                 (earthworks-for-area "semi-circular-bund-a" 10.0))
              125.0 0.1))

;;; ── 5. The recipe is built from the specification ─────────────────────────

(call-with-values (lambda () (land-transformation-records
                              #:technique "semi-circular-bund-a"
                              #:area-ha 10.0 #:rain-mm 350))
  (lambda (resources procs flows)
    (check "one process, whatever the scale" (= 1 (length procs)))
    (check "the recipe compiles to a planner template"
           (= 1 (length (compile-recipe procs flows))))

    ;; Labour follows from soil moved, which follows from the manual.
    (check "labour is derived from tabulated earthwork volume"
           (let ((w (find (lambda (f) (eq? 'work (recipe-flow-action f))) flows)))
             (near? (measure-has-numerical-value (recipe-flow-effort-quantity w))
                    (earthwork-labour-hours 1750.0) 1.0)))

    (check "water available counts the catchment as well as the treated area"
           (let ((f (find (lambda (f) (equal? "seasonal-rainfall"
                                              (recipe-flow-resource-conforms-to f))) flows)))
             (near? (measure-has-numerical-value (recipe-flow-resource-quantity f))
                    (* 10.0 (+ 1.0 1.4) 10.0 350) 1.0)))

    ;; ── the restore half of the shed's recharge envelope ──────────────────
    ;; worlds/doon-shed.scm declares a `groundwater` fragility and calls it a recharge
    ;; envelope. Earthworks are what recharges it, so the restore flow has to
    ;; produce THAT spec — not a private synonym that nets against nothing.
    (check "earthworks restore the `groundwater` spec the shed declares"
           (find (lambda (f) (and (eq? 'produce (recipe-flow-action f))
                                  (equal? "groundwater"
                                          (recipe-flow-resource-conforms-to f))))
                 flows))

    ;; The model hazard: a cheap restore run without limit against a soft
    ;; barrier. The bound is PHYSICAL — recharge redirects runoff, it does not
    ;; create water — so infiltration can never exceed the rain consumed.
    (check "recharge never exceeds the rainfall the process consumes"
           (let ((rain (find (lambda (f) (equal? "seasonal-rainfall"
                                                 (recipe-flow-resource-conforms-to f))) flows))
                 (rech (find (lambda (f) (and (eq? 'produce (recipe-flow-action f))
                                              (equal? "groundwater"
                                                      (recipe-flow-resource-conforms-to f)))) flows)))
             (<= (measure-has-numerical-value (recipe-flow-resource-quantity rech))
                 (measure-has-numerical-value (recipe-flow-resource-quantity rain)))))))

;; The bound has to hold where it actually bites — a big catchment ratio and a
;; wet season, where impounded volume would otherwise outrun the rain.
(check "the physical bound holds at the large design in a wet year too"
       (call-with-values (lambda () (land-transformation-records
                                     #:technique "semi-circular-bund-b"
                                     #:area-ha 1.0 #:rain-mm 1200))
         (lambda (r p flows)
           (let ((rain (find (lambda (f) (equal? "seasonal-rainfall"
                                                 (recipe-flow-resource-conforms-to f))) flows))
                 (rech (find (lambda (f) (and (eq? 'produce (recipe-flow-action f))
                                              (equal? "groundwater"
                                                      (recipe-flow-resource-conforms-to f)))) flows)))
             (<= (measure-has-numerical-value (recipe-flow-resource-quantity rech))
                 (measure-has-numerical-value (recipe-flow-resource-quantity rain)))))))

;;; ── The spillover: recorded, split, and not silently acting ───────────────
;;
;; The 3x claim covers two mechanisms at once, and they need different answers.
;;
;; Downstream infiltration needs no coefficient — it needs the limit held at the
;; right SCALE. `groundwater` is a `within` fragility over the shed
;; (knowledge/doon-shed.scm), so draws and restores from every place at or under
;; the watershed meet in one pooled budget, and upslope recharge relieves the
;; barrier a downslope well is held by. Proved in frag-restore-symmetry-test:
;; a farm that cannot recharge is freed by its neighbour's repair.
;;
;; Held as a per-spec RATE instead — as this file once claimed — each plot gets
;; a private envelope and the shed feels nothing as the table falls. That is the
;; distributed-draw failure playnet.typ §"Shared budgets" names.
;;
;; Wind protection is spec-to-spec and would need an eco-couple edge. Niger
;; reports one number for both halves, so neither gets it.

(check "the offsite factor is recorded for research, not multiplied into a flow"
       (and (= 3.0 *restoration-offsite-factor*)
            (call-with-values (lambda () (land-transformation-records #:area-ha 1.0))
              (lambda (r p flows)
                (not (any (lambda (f)
                            (string-contains (or (recipe-flow-resource-conforms-to f) "")
                                             "offsite"))
                          flows))))))

(check "the coupling is declared empty rather than seeded with a guess"
       (null? *restoration-coupling*))

;; The same builder serves a field and a national programme.
(check "the region-scale lead builds from the same records function"
       (call-with-values (lambda () (land-transformation-records
                                     #:technique "semi-circular-bund-b"
                                     #:area-ha (lead-ref 'region 'scale-ha)))
         (lambda (r p f) (and (= 1 (length p)) (> (length f) 4)))))

(check "treating 300,000 ha moves tens of millions of cubic metres"
       (> (earthworks-for-area "semi-circular-bund-b" (lead-ref 'region 'scale-ha))
          3.0e7))

;;; ── 6. The separation itself ──────────────────────────────────────────────
;;
;; The property this file exists to hold: recipe quantities come from the
;; manual. A lead may carry a scale and a rainfall to run a scenario AT, and
;; must never carry an earthwork or labour coefficient.

(check "no lead carries an earthworks or labour coefficient"
       (every (lambda (l)
                (not (any (lambda (field) (assq field (cdr l)))
                          '(earthworks-m3 earthworks-ha-m3 labour-days
                            per-ha radius-m hours-per-m3))))
              *land-transformation-leads*))

(check "every spec, and no lead, cites a manual"
       (and (every (lambda (s) (assq 'cite (cdr s))) *earthwork-specs*)
            (every (lambda (l) (not (assq 'cite (cdr l)))) *land-transformation-leads*)))

;; Labour used to be the one figure neither source gave. FAO §5.7 Table 24
;; states volume AND person-days per hectare across two spacings and two stone
;; sizes, and every row divides to the same rate — which is what makes it a
;; rate rather than four readings.
(check "labour comes from the manual: 2.0 person-days per m3 on site"
       (= 2.0 *labour-days-per-m3-onsite*))
(check "carrying the material costs 50% more, per the same table"
       (= 1.5 (/ *labour-days-per-m3-carried* *labour-days-per-m3-onsite*)))
(check "a carried scheme bills half again the hours of an on-site one"
       (let ((on (earthwork-labour-hours 100.0))
             (carried (earthwork-labour-hours 100.0 #:carried? #t)))
         (and (> carried on) (near? (/ carried on) 1.5 0.001))))
(check "the person-day → hour conversion is stated, not assumed"
       (near? (earthwork-labour-hours 1.0) (* 2.0 *workday-hours*) 0.001))

(format #t "~%~a passed, ~a failed~%~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
